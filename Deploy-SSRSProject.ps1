#requires -version 2.0
[CmdletBinding()]
param (
    [parameter(Mandatory=$true)]
    [ValidatePattern('\.rptproj$')]
    [ValidateScript({ Test-Path -PathType Leaf -Path $_ })]
    [string]
    $Path,
    
    [parameter(
        ParameterSetName='Configuration',
        Mandatory=$true)] 
    [string]
    $Configuration,
    
    [parameter(
        ParameterSetName='Target',
        Mandatory=$true)]
    [ValidatePattern('^https?://')]
    [string]
    $ServerUrl,
    
    [parameter(
        ParameterSetName='Target',
        Mandatory=$true)]
    [string]
    $Folder,

    [parameter(
        ParameterSetName='Target',
        Mandatory=$true)]
    [string]
    $DataSourceFolder,
    
    [parameter(ParameterSetName='Target')]
    [switch]
    $OverwriteDataSources,
	
	[parameter(ParameterSetName='Target')]
	[string]
	$DataSetFolder,
	
	[parameter(ParameterSetName='Target')]
	[switch]
	$OverwriteDataSets,

    [System.Management.Automation.PSCredential]
    $Credential
)

function New-XmlNamespaceManager ($XmlDocument, $DefaultNamespacePrefix) {
    $NsMgr = New-Object -TypeName System.Xml.XmlNamespaceManager -ArgumentList $XmlDocument.NameTable
    $DefaultNamespace = $XmlDocument.DocumentElement.GetAttribute('xmlns')
    if ($DefaultNamespace -and $DefaultNamespacePrefix) {
        $NsMgr.AddNamespace($DefaultNamespacePrefix, $DefaultNamespace)
    }
    return ,$NsMgr # unary comma wraps $NsMgr so it isn't unrolled
}

function Normalize-SSRSFolder (
    [string]$Folder
) {
    if (-not $Folder.StartsWith('/')) {
        $Folder = '/' + $Folder
    }
    
    return $Folder
}

function New-SSRSFolder (
    $Proxy,
    [string]
    $Name
) {
    Write-Verbose "New-SSRSFolder -Name $Name"

    $Name = Normalize-SSRSFolder -Folder $Name

    if ($Proxy.GetItemType($Name) -ne 'Folder') {
        $Parts = $Name -split '/'
        $Leaf = $Parts[-1]
        $Parent = $Parts[0..($Parts.Length-2)] -join '/'

        if ($Parent) {
            New-SSRSFolder -Proxy $Proxy -Name $Parent
        } else {
            $Parent = '/'
        }
        
        $Proxy.CreateFolder($Leaf, $Parent, $null)
    }
}

function New-SSRSDataSource (
    $Proxy,
    [string]$RdsPath,
    [string]$Folder,
    [switch]$Overwrite
) {
    Write-Verbose "New-SSRSDataSource -RdsPath $RdsPath -Folder $Folder"

#     $Folder = Normalize-SSRSFolder -Folder $Folder

    [xml]$Rds = Get-Content -Path $RdsPath
    $ConnProps = $Rds.RptDataSource.ConnectionProperties
    
    $Definition = New-Object -TypeName SSRS.ReportingService2010.DataSourceDefinition
    $Definition.ConnectString = $ConnProps.ConnectString
    $Definition.Extension = $ConnProps.Extension 
    if ([Convert]::ToBoolean($ConnProps.IntegratedSecurity)) {
        $Definition.CredentialRetrieval = 'Integrated'
    }
    
    $DataSource = New-Object -TypeName PSObject -Property @{
        Name = $Rds.RptDataSource.Name
        Path =  $Folder + '/' + $Rds.RptDataSource.Name
    }
    
    if ($Overwrite -or $Proxy.GetItemType($DataSource.Path) -eq 'Unknown') {
        $Proxy.CreateDataSource($DataSource.Name, $Folder, $Overwrite, $Definition, $null)
    }
    
    return $DataSource
}


function New-SSRSDataSet (
	$Proxy,
	[string]$RsdPath,
	[string]$Folder,
	[switch]$Overwrite
) {
	Write-Verbose "New-SSRSDataSet -RsdPath $RsdPath -Folder $Folder"
	
	[xml]$Rsd = Get-Content -Path $RsdPath
	#$DSProps = $Rsd.SharedDataset.DataSet
	$byteArray = gc $RsdPath -Encoding byte
	
	#$DSDefinition = New-Object -TypeName SSRS.ReportingService2010.DataSetDefinition
	#$DSDefinition.Query = $DSProps.Query
	
	$DataSet = New-Object -TypeName PSObject -Property @{
		Name = $Rsd.SharedDataSet.DataSet.Name
		Path = $Folder + '/' + $Rsd.SharedDataSet.DataSet.Name
	}
	

	[ref]$warnings = $null
	if ($Overwrite -or $Proxy.GetItemType($DataSet.Path) -eq 'Unknown') {
		$Proxy.CreateCatalogItem("DataSet", $DataSet.Name, $Folder, $true, $byteArray, $null, $warnings)
	}

	return $DataSet
}


$script:ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$PSScriptRoot = $MyInvocation.MyCommand.Path | Split-Path

$Path = $Path | Convert-Path
$ProjectRoot = $Path | Split-Path
[xml]$Project = Get-Content -Path $Path

if ($PSCmdlet.ParameterSetName -eq 'Configuration') {
    $Config = & $PSScriptRoot\Get-SSRSProjectConfiguration.ps1 -Path $Path -Configuration $Configuration
    $ServerUrl = $Config.ServerUrl
    $Folder = $Config.Folder
    $DataSourceFolder = $Config.DataSourceFolder
	$DataSetFolder = $Config.DataSetFolder
    $OverwriteDataSources = $Config.OverwriteDataSources
	$OverwriteDataSets = $Config.OverwriteDataSets
}


$Folder = Normalize-SSRSFolder -Folder $Folder
$DataSourceFolder = Normalize-SSRSFolder -Folder $DataSourceFolder
$DataSetFolder = Normalize-SSRSFolder -Folder $DataSetFolder

$Proxy = & $PSScriptRoot\New-SSRSWebServiceProxy.ps1 -Uri $ServerUrl -Credential $Credential

New-SSRSFolder -Proxy $Proxy -Name $Folder
New-SSRSFolder -Proxy $Proxy -Name $DataSourceFolder
New-SSRSFolder -Proxy $Proxy -Name $DataSetFolder

$DataSourcePaths = @{}
$Project.SelectNodes('Project/DataSources/ProjectItem') |
    ForEach-Object {
        $RdsPath = $ProjectRoot | Join-Path -ChildPath $_.FullPath
        $DataSource = New-SSRSDataSource -Proxy $Proxy -RdsPath $RdsPath -Folder $DataSourceFolder
        $DataSourcePaths.Add($DataSource.Name, $DataSource.Path)
    }

# I may have to comment this whole section out, but lets see how it works.

$DataSetPaths = @{}
$Project.SelectNodes('Project/DataSets/ProjectItem') |
	ForEach-Object {
		$RsdPath = $ProjectRoot | Join-Path -ChildPath $_.FullPath
		$DataSet = New-SSRSDataSet -Proxy $Proxy -RsdPath $RsdPath -Folder $DataSetFolder
		$DataSetPaths.Add($DataSet.Name, $DataSet.Path)
	}


$Project.SelectNodes('Project/Reports/ProjectItem') |
    ForEach-Object {
        $RdlPath = $ProjectRoot | Join-Path -ChildPath $_.FullPath
        [xml]$Definition = Get-Content -Path $RdlPath
        $NsMgr = New-XmlNamespaceManager $Definition d

        $RawDefinition = Get-Content -Encoding Byte -Path $RdlPath
        
        $Name = $_.Name -replace '\.rdl$',''
		$warnings = @();
        
        Write-Verbose "Creating report $Name"
        $Results = $Proxy.CreateCatalogItem("Report", $Name, $Folder, $true, $RawDefinition, $null, [ref]$warnings)
        if ($Results -and ($warnings | Where-Object { $_.Severity -eq 'Error' })) {
            throw 'Error uploading report'
        }

        $Xpath = 'd:Report/d:DataSources/d:DataSource/d:DataSourceReference/..'
        $DataSources = $Definition.SelectNodes($Xpath, $NsMgr) |
            ForEach-Object {
                $DataSourcePath = $DataSourcePaths[$_.DataSourceReference]
                if (-not $DataSourcePath) {
                    throw "Invalid data source reference '$($_.DataSourceReference)' in $RdlPath"
                }
                $Reference = New-Object -TypeName SSRS.ReportingService2010.DataSourceReference
                $Reference.Reference = $DataSourcePath
                $DataSource = New-Object -TypeName SSRS.ReportingService2010.DataSource
                $DataSource.Item = $Reference
                $DataSource.Name = $_.Name
                $DataSource
            }
        if ($DataSources) {        
            $Proxy.SetItemDataSources($Folder + '/' + $Name, $DataSources)
        }
    }
