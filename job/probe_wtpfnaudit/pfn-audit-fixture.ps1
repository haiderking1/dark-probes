# The capture owns only this audit policy and the files in its scratch
# directory. The policy ID is checked before the probe makes any changes.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ciTool = Join-Path $env:SystemRoot 'System32\CiTool.exe'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$id = [Guid]::NewGuid()
$policyId = $id.ToString('B')
$xml = @"
<SiPolicy xmlns="urn:schemas-microsoft-com:sipolicy" PolicyType="Base Policy">
  <VersionEx>1.0.0.0</VersionEx>
  <PolicyID>$policyId</PolicyID>
  <BasePolicyID>$policyId</BasePolicyID>
  <PlatformID>{2E07F7E6-194C-4D20-B7C9-6F44A6C5A234}</PlatformID>
  <Rules>
    <Rule><Option>Enabled:UMCI</Option></Rule>
    <Rule><Option>Enabled:Audit Mode</Option></Rule>
    <Rule><Option>Enabled:Unsigned System Integrity Policy</Option></Rule>
    <Rule><Option>Enabled:Update Policy No Reboot</Option></Rule>
  </Rules>
  <EKUs/>
  <FileRules>
    <Allow ID="ID_ALLOW_A_1" FriendlyName="Owned package" PackageFamilyName="DarkOwnedWintrustProbe_5pq7tkvbnxv54" MinimumFileVersion="0.0.0.0" PackageVersion="1.0.0.0"/>
  </FileRules>
  <Signers/>
  <SigningScenarios>
    <SigningScenario Value="12" ID="ID_SIGNINGSCENARIO_WINDOWS" FriendlyName="Owned user scenario">
      <ProductSigners><FileRulesRef><FileRuleRef RuleID="ID_ALLOW_A_1"/></FileRulesRef></ProductSigners>
    </SigningScenario>
  </SigningScenarios>
  <UpdatePolicySigners/><CiSigners/><HvciOptions>0</HvciOptions>
</SiPolicy>
"@

function Invoke-FixtureProcess($Label, $Executable, $Arguments, $Expected, $Deadline) {
    $stdout = "$Label.stdout"
    $stderr = "$Label.stderr"
    $parameters = @{
        FilePath = $Executable
        PassThru = $true
        NoNewWindow = $true
        WorkingDirectory = (Get-Location).Path
        RedirectStandardOutput = $stdout
        RedirectStandardError = $stderr
    }
    if ($Arguments.Count) { $parameters.ArgumentList = $Arguments }
    $child = Start-Process @parameters
    try {
        $null = $child.Handle
        if (-not $child.WaitForExit($Deadline)) {
            if (-not $child.HasExited) { $child.Kill() }
            $null = $child.WaitForExit(5000)
            throw "$Label timed out"
        }
        if ($child.ExitCode -ne $Expected) {
            $detail = (Get-Content -LiteralPath $stderr -TotalCount 4) -join ' '
            if (!$detail) { $detail = (Get-Content -LiteralPath $stdout -TotalCount 4) -join ' ' }
            throw "$Label exited $($child.ExitCode) $detail"
        }
        Get-Content -LiteralPath $stdout -Raw
    } finally {
        $child.Dispose()
    }
}

function Get-Policies($Label) {
    $result = Invoke-FixtureProcess $Label $ciTool @('--list-policies', '--json') 0 15000 |
        ConvertFrom-Json
    if (!$result -or !$result.PSObject.Properties['Policies']) { throw 'CiTool policy list missing' }
    foreach ($policy in $result.Policies) {
        if (!$policy.PSObject.Properties['PolicyID']) { throw 'CiTool policy ID missing' }
        $null = [Guid]$policy.PolicyID
        $policy
    }
}

function Get-OwnedPolicy($Policies) {
    $Policies | Where-Object { ([Guid]$_.PolicyID) -eq $id }
}

function Get-PolicySnapshot($Policies) {
    ConvertTo-Json -InputObject @($Policies | Sort-Object PolicyID) -Depth 8 -Compress
}

function Test-PackageQuery($Phase) {
    foreach ($width in 64, 32) {
        $name = if ($width -eq 64) { 'probe_wtpfnapi.exe' } else { 'probe_wtpfnapi32.exe' }
        "package-policy-phase $Phase $width"
        Invoke-FixtureProcess "$Phase-$width" (Join-Path $PSScriptRoot $name) @() 42 7000
    }
}

$baseline = @(Get-Policies 'original')
if (@(Get-OwnedPolicy $baseline).Count) { throw 'test policy ID already present' }
$snapshot = Get-PolicySnapshot $baseline
Test-PackageQuery 'original'
[IO.File]::WriteAllText((Join-Path (Get-Location) 'owned-pfn.xml'), $xml)
$null = Invoke-FixtureProcess 'compile' $powershell @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-Command',
    '$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop; ConvertFrom-CIPolicy -XmlFilePath .\owned-pfn.xml -BinaryFilePath .\owned-pfn.cip | Out-Null'
) 0 45000
if (!(Test-Path -LiteralPath '.\owned-pfn.cip' -PathType Leaf)) { throw 'compiled fixture policy missing' }
try {
    $null = Invoke-FixtureProcess 'add' $ciTool @('--update-policy', '.\owned-pfn.cip', '--json') 0 30000
    $current = @(Get-Policies 'registered')
    $own = @(Get-OwnedPolicy $current)
    if ($own.Count -ne 1 -or $own[0].IsSystemPolicy -isnot [bool] -or $own[0].IsSystemPolicy) {
        throw 'cannot identify the added test policy'
    }
    $active = $own[0].PSObject.Properties['IsEnforced']
    $state = if ($active -and $active.Value -is [bool]) { [int]$active.Value } else { -1 }
    "package-policy-registered 1 $state"
    Test-PackageQuery 'registered'
} finally {
    $pending = @(Get-Policies 'before-removal')
    $present = @(Get-OwnedPolicy $pending)
    if ($present.Count) {
        if ($present.Count -ne 1 -or $present[0].IsSystemPolicy -isnot [bool] -or $present[0].IsSystemPolicy) {
            throw 'cannot establish ownership of the policy to remove'
        }
        $null = Invoke-FixtureProcess 'remove' $ciTool @('--remove-policy', $policyId, '--json') 0 25000
    }
    $restored = @(Get-Policies 'after-removal')
    $ok = (Get-PolicySnapshot $restored) -ceq $snapshot
    "package-policy-restored $([int]$ok)"
    if (!$ok) { throw 'original CiTool policy list was not restored' }
}
exit 42
