<#
.SYNOPSIS
    Governance/DLM-specific checks layered on top of FileShareCleanup.Common.ps1.
    Dot-source both this file and Common.ps1 - do not run it directly.

.DESCRIPTION
    These functions implement the technical rules from the documented
    "DLM POC - Bulk Deletion Process Flow": department-ownership scoping,
    legal hold checking, custodian (owner) resolution with a fallback to
    file Author metadata, AD active/inactive lookup, dual-date ("aged data")
    evaluation, and duplicate/multi-team detection.

    Fail-closed everywhere: any function here that can't conclusively
    determine an answer (unmapped department, unreachable legal hold
    register, unresolvable identity, AD lookup failure) returns a result
    that routes to RETAIN or manual review - never a result that lets an
    item proceed toward deletion by default. Do not change this without
    good reason; it's the single most important property of this module.

    Department mapping and legal hold register lookups are deliberately
    NOT hard-coded to a specific data source (folder convention, AD group,
    spreadsheet, etc.) - callers pass a resolver scriptblock so the real
    source can be plugged in once it's confirmed, without changing this file.
#>

# ---------------------------------------------------------------------------
# Department scope (Phase 1 step 2)
# ---------------------------------------------------------------------------

function Test-DepartmentInScope {
    <#
    Resolves an item's department via the caller-supplied -DepartmentResolver
    scriptblock (called as `& $DepartmentResolver $Path`, must return a
    department string or $null if unknown) and checks it against
    -InScopeDepartments.

    Returns one of: "InScope", "OutOfScope", "Unresolved-ManualReview".
    Fail-closed: an unresolvable department is neither included nor silently
    dropped - it's routed to manual review.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [scriptblock] $DepartmentResolver,
        [string[]] $InScopeDepartments = @('Tech', 'Technology', 'T&C')
    )

    $department = try { & $DepartmentResolver $Path } catch { $null }

    if (-not $department) { return "Unresolved-ManualReview" }
    if ($InScopeDepartments -contains $department) { return "InScope" }
    return "OutOfScope"
}

# ---------------------------------------------------------------------------
# Legal hold (Phase 1 step 3)
# ---------------------------------------------------------------------------

function Test-LegalHold {
    <#
    Resolves legal hold status via the caller-supplied -LegalHoldResolver
    scriptblock (called as `& $LegalHoldResolver $Path $Owner`, must return
    $true/$false, or $null if unknown/ambiguous).

    Returns $true (on hold - RETAIN) whenever the resolver returns $true,
    $null, or throws. Only returns $false when the resolver explicitly and
    successfully confirms no hold applies. This is deliberately biased
    toward false positives (over-retaining) - a missed legal hold is a much
    worse outcome than an unnecessarily retained file.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [scriptblock] $LegalHoldResolver,
        $Owner = $null
    )

    $result = try { & $LegalHoldResolver $Path $Owner } catch { $null }

    if ($null -eq $result) { return $true }
    return [bool]$result
}

# ---------------------------------------------------------------------------
# Custodian (owner) resolution with Author fallback
# ---------------------------------------------------------------------------

$script:GenericOwnerAccounts = @(
    'BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM', 'BUILTIN\Users', 'NT AUTHORITY\Authenticated Users'
)
$script:AuthorsPropertyIndex = $null

function Get-FileAuthorProperty {
    <#
    Reads the "Authors" extended shell property (document metadata - works
    for Office documents and many other file types that carry author info,
    not just NTFS ACLs) via the Shell.Application COM object. This is the
    fallback used when NTFS Owner is missing/unreliable, not the primary
    path - only invoke it for files that actually need it, since creating
    the Shell COM object and enumerating properties is comparatively slow.
    #>
    param([Parameter(Mandatory)] [string] $Path)

    $shell = $null
    try {
        $folder = Split-Path $Path -Parent
        $file = Split-Path $Path -Leaf
        $shell = New-Object -ComObject Shell.Application
        $ns = $shell.Namespace($folder)
        if (-not $ns) { return $null }
        $item = $ns.ParseName($file)
        if (-not $item) { return $null }

        # The property-index-to-name mapping is stable within a session, so the
        # "Authors" index is found once and cached rather than re-searched per file.
        if ($null -eq $script:AuthorsPropertyIndex) {
            for ($i = 0; $i -lt 300; $i++) {
                if ($ns.GetDetailsOf($null, $i) -eq 'Authors') {
                    $script:AuthorsPropertyIndex = $i
                    break
                }
            }
        }
        if ($null -eq $script:AuthorsPropertyIndex) { return $null }

        $value = $ns.GetDetailsOf($item, $script:AuthorsPropertyIndex)
        if ([string]::IsNullOrWhiteSpace($value)) { return $null }
        return $value
    }
    catch {
        return $null
    }
    finally {
        if ($shell) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null }
    }
}

function Resolve-FileCustodian {
    <#
    Resolves an identity for a file: tries NTFS Owner first (Get-ItemOwner,
    from Common.ps1). Falls back to the file's Author metadata if Owner is
    blank, an unresolved/orphaned SID, or a known generic/shared account -
    all common on old shares after account migrations or admin-performed
    copies/restores that leave the wrong owner behind.

    Returns a PSCustomObject: Identity (string or $null), CustodianSource
    ("Owner" / "Author" / "Unresolved"). Unresolved is a valid, expected
    outcome - callers must route it to manual review, not assume inactive.
    #>
    param([Parameter(Mandatory)] [string] $Path)

    $owner = Get-ItemOwner -Path $Path
    $isOrphanedSid = $owner -and ($owner -match '^S-1-\d+(-\d+)+$')
    $isGeneric = $owner -and ($script:GenericOwnerAccounts -contains $owner)

    if ($owner -and -not $isOrphanedSid -and -not $isGeneric) {
        return [PSCustomObject]@{ Identity = $owner; CustodianSource = "Owner" }
    }

    $author = Get-FileAuthorProperty -Path $Path
    if ($author) {
        return [PSCustomObject]@{ Identity = $author; CustodianSource = "Author" }
    }

    return [PSCustomObject]@{ Identity = $null; CustodianSource = "Unresolved" }
}

# ---------------------------------------------------------------------------
# AD active/inactive lookup (Phase 2 step 7 / Phase 3)
# ---------------------------------------------------------------------------

$script:ADStatusCache = @{}

function Get-ADUserActiveStatus {
    <#
    Resolves a custodian identity to AD Enabled status, cached per unique
    identity for the lifetime of the session - never call this per file at
    scale; millions of files typically share only hundreds/thousands of
    unique owners, so the cache is what keeps this fast and keeps load off
    domain controllers.

    Returns "Active", "Inactive", or "Unresolved" (identity blank, no
    matching AD account - e.g. an orphaned SID or a departed/purged user -
    cross-domain lookup failure, or the ActiveDirectory module/connectivity
    unavailable). "Unresolved" must be treated as manual review, never as
    "assume inactive."
    #>
    param([string] $Identity)

    if (-not $Identity) { return "Unresolved" }
    if ($script:ADStatusCache.ContainsKey($Identity)) { return $script:ADStatusCache[$Identity] }

    $status = try {
        $samAccountName = ($Identity -split '\\')[-1]
        $adUser = Get-ADUser -Identity $samAccountName -Properties Enabled -ErrorAction Stop
        if ($adUser.Enabled) { "Active" } else { "Inactive" }
    }
    catch {
        "Unresolved"
    }

    $script:ADStatusCache[$Identity] = $status
    return $status
}

# ---------------------------------------------------------------------------
# Aged data (Phase 2 step 6) - requires BOTH LastWriteTime and LastAccessTime
# ---------------------------------------------------------------------------

function Test-AgedData {
    <#
    Phase 2 step 6 of the documented process: a file/folder only qualifies
    as "aged" if BOTH its Last Modified AND Last Access dates predate the
    cutoff - stricter than the general-purpose engine in Common.ps1, which
    only checks LastWriteTime.

    IMPORTANT: verify LastAccessTime is trustworthy on the target server
    before relying on this (run `fsutil behavior query disablelastaccess`).
    Many Windows file servers disable last-access tracking for performance,
    which freezes/invalidates this field - a frozen old value would make
    every file look "aged" regardless of real usage, which is unsafe.
    #>
    param(
        [Parameter(Mandatory)] [datetime] $LastWriteTime,
        [Parameter(Mandatory)] [datetime] $LastAccessTime,
        [Parameter(Mandatory)] [datetime] $Cutoff
    )

    return ($LastWriteTime -lt $Cutoff) -and ($LastAccessTime -lt $Cutoff)
}

# ---------------------------------------------------------------------------
# Duplicate / multi-team detection (Phase 2 step 7, Phase 3 step 8)
# ---------------------------------------------------------------------------

function Find-DuplicateGroups {
    <#
    Streams files under -Path (recursively) and groups them by
    Filename + Size + LastWriteTime (the documented duplicate definition -
    metadata-based, not content-hash). For each file, resolves a custodian
    (Resolve-FileCustodian) and AD status (Get-ADUserActiveStatus), so each
    returned group already carries what's needed to answer "does an active-
    user copy exist" (Phase 2 step 7) and "Active User Copy Exists?"
    (Phase 3 step 8).

    Only groups with more than one member are returned. Uses an in-memory
    hashtable index - fine for a single share/run of realistic size; if
    scanning consistently turns up millions of files, swap this for a
    SQLite-backed index (see TODO.md) rather than growing this in-memory
    structure indefinitely.
    #>
    param(
        [Parameter(Mandatory)] [string[]] $Path,
        [switch] $IncludeZeroByte
    )

    $index = @{}

    foreach ($root in $Path) {
        Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { (-not (Test-ExcludedPath -Path $_.FullName)) -and ($IncludeZeroByte -or $_.Length -gt 0) } |
            ForEach-Object {
                $key = "$($_.Name)|$($_.Length)|$($_.LastWriteTime.ToString('o'))"
                $custodian = Resolve-FileCustodian -Path $_.FullName
                $adStatus = Get-ADUserActiveStatus -Identity $custodian.Identity

                $entry = [PSCustomObject]@{
                    Path            = $_.FullName
                    Identity        = $custodian.Identity
                    CustodianSource = $custodian.CustodianSource
                    ADStatus        = $adStatus
                    LastWriteTime   = $_.LastWriteTime
                    LastAccessTime  = $_.LastAccessTime
                }

                if (-not $index.ContainsKey($key)) { $index[$key] = [System.Collections.Generic.List[object]]::new() }
                $index[$key].Add($entry)
            }
    }

    $index.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 } | ForEach-Object {
        [PSCustomObject]@{
            GroupKey           = $_.Key
            Members            = $_.Value
            HasActiveOwnerCopy = ($_.Value | Where-Object { $_.ADStatus -eq "Active" }).Count -gt 0
        }
    }
}

function Test-MultiTeamUsage {
    <#
    For a duplicate group (from Find-DuplicateGroups), checks whether its
    member paths resolve to more than one distinct department via the
    caller-supplied -DepartmentResolver. Used to decide between "Keep Active
    Copy, Delete Inactive Copy" (single department, automatic) and "flag for
    manual System-of-Record review" (multiple departments, per the
    documented Phase 3 team-lead review step).
    #>
    param(
        [Parameter(Mandatory)] $DuplicateGroup,
        [Parameter(Mandatory)] [scriptblock] $DepartmentResolver
    )

    $departments = $DuplicateGroup.Members |
        ForEach-Object { try { & $DepartmentResolver $_.Path } catch { $null } } |
        Where-Object { $_ } |
        Sort-Object -Unique

    return $departments.Count -gt 1
}
