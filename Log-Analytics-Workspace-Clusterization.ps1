<#
    .DESCRIPTION
        A runbook leveraging Managed Identity to check if workspaces are properly clustered by region. 

    .NOTES
        AUTHOR: Philip Baumann
        LASTEDIT: Jan 3, 2021
    .COMPANYNAME 
        Microsoft
    .TAGS 
        Log Analytics, Azure Automation, Powershell
#>

# Ensures you do not inherit an AzContext in your runbook
Disable-AzContextAutosave -Scope Process

Function Get-Usage-Workspace{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [Microsoft.Azure.Commands.OperationalInsights.Models.PSWorkspace] $Workspace 
    )

    PROCESS {
        Write-Verbose -Message ("Checking workspace usage for " + $Workspace.Name)
        $Results = Invoke-AzOperationalInsightsQuery -Workspace $Workspace -Query "Usage | where TimeGenerated > startofday(ago(30d)) | where StartTime > startofday(ago(30d)) | where IsBillable == true | summarize sum(Quantity)/1000"
        #Write-Verbose -Message ("Workspace " + $Workspace.Name + " has usage " + $Results.Results.Column1.ToString())
        return ([int]$Results.Results.Column1.ToString() / 30)
    }

}

Function Get-Usage-AssociatedWorkspace{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [Microsoft.Azure.Management.OperationalInsights.Models.AssociatedWorkspace] $Workspace 
    )

    PROCESS {
        Write-Verbose -Message ("Checking workspace usage for " + $Workspace.WorkspaceName)
        $Results = Invoke-AzOperationalInsightsQuery -WorkspaceId $Workspace.WorkspaceId -Query "Usage | where TimeGenerated > startofday(ago(30d)) | where StartTime > startofday(ago(30d)) | where IsBillable == true | summarize sum(Quantity)/1000"
        #Write-Verbose -Message ("Workspace " + $Workspace.WorkspaceName + " has usage " + $Results.Results.Column1.ToString())
        return ([int]$Results.Results.Column1.ToString() / 30)
    }

}

Function Check-Results{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [hashtable]  $ProposedClusters,
        [Parameter(Mandatory = $true)] [hashtable]  $CurrentClusters,
        [Parameter(Mandatory = $true)] [Microsoft.Azure.Commands.Profile.Models.PSAzureSubscription]  $Sub
    )

    PROCESS {
        Write-Verbose -Message "Checking results..."
        $Results = @()

        foreach ($Cluster in $CurrentClusters.GetEnumerator())
        {
            # TODO: To examine whether it's greater than the next tier, not just double the current Sku which works for all but 2000GB to 5000GB.
            # TODO: Check if tier needs to be lowered.
            if ($CurrentClusterVolume[$Cluster.Name] -gt (2*$Cluster.Value.Sku.Capacity)) {
                $ResultSentence = "We should consider upgrading cluster " + $Cluster.Name + " to the next commitment tier as its daily ingestion is " + $CurrentClusterVolume[$Cluster.Name] + " with a daily capacity of " + $Cluster.Value.Sku.Capacity + " in " + $Sub.Name + "."
                $Results += ,$ResultSentence  
            }
            if ($CurrentClusterVolume[$Cluster.Name] -lt 500) {
                $ResultSentence = "We should consider removing cluster " + $Cluster.Name + " as its daily ingestion is " + $CurrentClusterVolume[$Cluster.Name] + " in " + $Sub.Name + "."
                $Results += ,$ResultSentence
            }
        }

        foreach ($Cluster in $ProposedClusters.GetEnumerator())
        {
            if ($Cluster.Value -gt 500) 
            {
                $ResultSentence = "We should consider creating a cluster in " + $Cluster.Name + " given the daily ingestion in this region is " + $Cluster.Value + " in " + $Sub.Name + "."
                $Results += ,$ResultSentence
            }
        }
        
        return $Results
    }
}

Function Run-Clusterization() {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [Microsoft.Azure.Commands.Profile.Models.PSAzureSubscription]  $Sub
    )

    PROCESS {
        Write-Verbose -Message "Running clusterization..."
        $Results = @()
        $CurrentClusters = @{} # Mapping of location to cluster.
        $CurrentClusterVolume = @{} # Mapping of location to volume.
        $ProposedClusters = @{} # New hash of proposed location to volume. 

        $DedicatedClusters = Get-AzOperationalInsightsCluster
        foreach ($Cluster in $DedicatedClusters)
        {
            $ClusterLocation = ($Cluster.Location -replace '\s','').ToLower()
            $CurrentClusterVolume = $CurrentClusterVolume + @{$ClusterLocation=0}
            foreach ($Workspace in $Cluster.AssociatedWorkspaces)
            {            
                $CurrentClusterVolume[$ClusterLocation] += (Get-Usage-AssociatedWorkspace $Workspace -Verbose)
            }
            $CurrentClusters = $CurrentClusters + @{$ClusterLocation=$Cluster}
        }

        Write-Verbose -Message ("Possible locations: " + ($CurrentClusters | ConvertTo-Json -Compress) )

        # Get all Workspaces within the subscription
        $Workspaces = Get-AzOperationalInsightsWorkspace

        foreach ($Workspace in $Workspaces)
        {
            # Write-Verbose -Message ("Checking workspace " + $Workspace.Name)
            $WorkspaceLocation = ($Workspace.Location -replace '\s','').toLower()
            # Write-Verbose -Message ("Workspace location: " + $WorkspaceLocation)
            if ($CurrentClusters.Contains($WorkspaceLocation)) 
            {
                if ($Workspace.WorkspaceFeatures.ClusterResourceId -eq $null) 
                {
                    $ResultSentence = "Consider adding workspace " + $Workspace.Name + " to cluster in " + $WorkspaceLocation + " in subscription " + $Sub.Name + "."
                    $Results += ,$ResultSentence
                }
            }
            else 
            {
                if ($Workspace.WorkspaceFeatures.ClusterResourceId -ne $null) 
                {
                    $ResultSentence = "Consider adding workspace " + $Workspace.Name + " to cluster in " + $WorkspaceLocation + " in subscription " + $Sub.Name + "."
                    $Results += ,$ResultSentence
                }
                if ($ProposedClusters.ContainsKey($WorkspaceLocation))
                {
                    $ProposedClusters[$WorkspaceLocation] += (Get-Usage-Workspace $Workspace -Verbose)
                }
                else
                {
                    $ProposedClusters.Add($WorkspaceLocation, (Get-Usage-Workspace $Workspace -Verbose))
                }
            }
        }
        $Results += (Check-Results -ProposedClusters $ProposedClusters -CurrentClusters $CurrentClusters -Sub $Sub)
        return $Results
    }
    
}


$CommitmentTiers = 500,1000,2000,5000
try
{
    "Logging in to Azure..."
    Connect-AzAccount -Identity
}
catch {
    Write-Error -Message $_.Exception
    throw $_.Exception
}


$Subscriptions = Get-AzSubscription
$FinalResults = @()
foreach ($Sub in $Subscriptions) {
    Write-Output("------------------------ Running clusterization on ${Sub.Name} ------------------------")
    Set-AzContext -SubscriptionObject $Sub
    $Results = Run-Clusterization -Verbose -Sub $Sub
    $FinalResults = $FinalResults + $Results
    Write-Output("------------------------ Clusterization complete for ${Sub.Name} ------------------------")
}

if ($FinalResults.count -ne 0) {
    Write-Error -Message ($FinalResults | Out-String)
    throw $_.Exception
}
else 
{
    Write-Output ("There are no cluster efficiency changes recommended.")
}

Write-Output "Success!"