Function Remove-DbaOrphanUser {
<#
.SYNOPSIS
Drop orphan users with no existing login to map

.DESCRIPTION
An orphan user is defined by a user that does not have their matching login. (Login property = "").
If user is the owner of the schema with the same name and if if the schema does not have any underlying objects the schema will be dropped.
If user owns more than one schema, the owner of the schemas that does not have the same name as the user, will be changed to 'dbo'. If schemas have underlying objects, you must specify the -Force parameter so the user can be dropped.
If exists a login to map the drop will not be performed unless you specify the -Force parameter (only when calling from Repair-DbaOrphanUser.

.PARAMETER SqlInstance
The SQL Server instance.

.PARAMETER SqlCredential
Allows you to login to servers using SQL Logins as opposed to Windows Auth/Integrated/Trusted. To use:

$scred = Get-Credential, then pass $scred object to the -SqlCredential parameter.

Windows Authentication will be used if SqlCredential is not specified. SQL Server does not accept Windows credentials being passed as credentials. To connect as a different Windows user, run PowerShell as that user.

.PARAMETER Database
The database(s) to process - this list is autopopulated from the server. If unspecified, all databases will be processed.

.PARAMETER User
List of users to remove

.PARAMETER Force
If exists any schema which owner is the User, this will force the change of the owner to 'dbo'.
If exists a login to map the drop will not be performed unless you specify this parameter.

.PARAMETER WhatIf
Shows what would happen if the command were to run. No actions are actually performed. 			

.PARAMETER Confirm 		
Prompts you for confirmation before executing any changing operations within the command. 

.PARAMETER Silent
Replaces user friendly yellow warnings with bloody red exceptions of doom!
Use this if you want the function to throw terminating errors you want to catch.
	
.NOTES
Tags: Orphan
Author: Claudio Silva (@ClaudioESSilva)
Website: https://dbatools.io
Copyright: (C) Chrissy LeMaire, clemaire@gmail.com
License: GNU GPL v3 https://opensource.org/licenses/GPL-3.0

.LINK
https://dbatools.io/Remove-DbaOrphanUser

.EXAMPLE
Remove-DbaOrphanUser -SqlInstance sql2005

Will find and drop all orphan users without matching login of all databases present on server 'sql2005'

.EXAMPLE
Remove-DbaOrphanUser -SqlInstance sqlserver2014a -SqlCredential $cred

Will find and drop all orphan users without matching login of all databases present on server 'sqlserver2014a'. Will be verified using SQL credentials.

.EXAMPLE
Remove-DbaOrphanUser -SqlInstance sqlserver2014a -Database db1, db2 -Force

Will find all and drop orphan users even if exists their matching login on both db1 and db2 databases

.EXAMPLE
Remove-DbaOrphanUser -SqlInstance sqlserver2014a -User OrphanUser

Will remove from all databases the user OrphanUser only if not have their matching login

.EXAMPLE
Remove-DbaOrphanUser -SqlInstance sqlserver2014a -User OrphanUser -Force

Will remove from all databases the user OrphanUser EVEN if exists their matching login. First will change any schema that it owns to 'dbo'.

#>
	[CmdletBinding(SupportsShouldProcess = $true)]
	Param (
		[parameter(Mandatory = $true, ValueFromPipeline = $true)]
		[Alias("ServerInstance", "SqlServer")]
		[DbaInstanceParameter[]]$SqlInstance,
		[Alias("Credential")]
		[PSCredential][System.Management.Automation.CredentialAttribute()]
		$SqlCredential,
		[Alias("Databases")]
		[object[]]$Database,
		[parameter(Mandatory = $false, ValueFromPipeline = $true)]
		[object[]]$User,
		[switch]$Force,
		[switch]$Silent
	)
	
	process {
		
		foreach ($Instance in $SqlInstance) {
			Write-Message -Level Verbose -Message "Attempting to connect to $Instance"
			try {
				$server = Connect-SqlInstance -SqlInstance $Instance -SqlCredential $SqlCredential
			}
			catch {
				Write-Message -Level Warning -Message "Can't connect to $Instance or access denied. Skipping."
				continue
			}
			
			if (!$database) {
				$database = $server.Databases | Where-Object { $_.IsSystemObject -eq $false -and $_.IsAccessible -eq $true }
			}
			else {
				if ($pipedatabase) {
					$Source = $pipedatabase[0].parent.name
					$database = $pipedatabase.name
				}
				else {
					$database = $server.Databases | Where-Object { $_.IsSystemObject -eq $false -and $_.IsAccessible -eq $true -and ($database -contains $_.Name) }
				}
			}
			
			
			$CallStack = Get-PSCallStack | Select-Object -Property *
			if ($CallStack.Count -eq 1) {
				$StackSource = $CallStack[0].Command
			}
			else {
				#-2 because index base is 0 and we want the one before the last (the last is the actual command)
				$StackSource = $CallStack[($CallStack.Count - 2)].Command
			}
			
			if ($database) {
				$start = [System.Diagnostics.Stopwatch]::StartNew()
				
				foreach ($db in $database) {
					try {
						#if SQL 2012 or higher only validate databases with ContainmentType = NONE
						if ($server.versionMajor -gt 10) {
							if ($db.ContainmentType -ne [Microsoft.SqlServer.Management.Smo.ContainmentType]::None) {
								Write-Message -Level Warnig -Message "Database '$db' is a contained database. Contained databases can't have orphaned users. Skipping validation."
								Continue
							}
						}
						
						if ($StackSource -eq "Repair-DbaOrphanUser") {
							Write-Message -Level Verbose -Message "Call origin: Repair-DbaOrphanUser"
							#Will use collection from parameter ($User)
						}
						else {
							Write-Message -Level Verbose -Message "Validating users on database $db"
							
							if ($User.Count -eq 0) {
								#the third validation will remove from list sql users without login. The rule here is Sid with length higher than 16
								$User = $db.Users | Where-Object { $_.Login -eq "" -and ($_.ID -gt 4) -and (($_.Sid.Length -gt 16 -and $_.LoginType -eq [Microsoft.SqlServer.Management.Smo.LoginType]::SqlLogin) -eq $false) }
							}
							else {
								if ($pipedatabase) {
									$Source = $pipedatabase[0].parent.name
									$User = $pipedatabase.name
								}
								else {
									#the fourth validation will remove from list sql users without login. The rule here is Sid with length higher than 16
									$User = $db.Users | Where-Object { $_.Login -eq "" -and ($_.ID -gt 4) -and ($User -contains $_.Name) -and (($_.Sid.Length -gt 16 -and $_.LoginType -eq [Microsoft.SqlServer.Management.Smo.LoginType]::SqlLogin) -eq $false) }
								}
							}
						}
						
						if ($User.Count -gt 0) {
							Write-Message -Level Verbose -Message "Orphan users found"
							foreach ($dbuser in $User) {
								$SkipUser = $false
								
								$ExistLogin = $null
								
								if ($StackSource -ne "Repair-DbaOrphanUser") {
									#Need to validate Existing Login because the call does not came from Repair-DbaOrphanUser
									$ExistLogin = $server.logins | Where-Object {
										$_.Isdisabled -eq $False -and
										$_.IsSystemObject -eq $False -and
										$_.IsLocked -eq $False -and
										$_.Name -eq $dbuser.Name
									}
								}
								
								#Schemas only appears on SQL Server 2005 (v9.0)
								if ($server.versionMajor -gt 8) {
									
									#Validate if user owns any schema
									$Schemas = @()
									
									$Schemas = $db.Schemas | Where-Object Owner -eq $dbuser.Name
									
									if (@($Schemas).Count -gt 0) {
										Write-Message -Level Verbose -Message "User $dbuser owns one or more schemas."
										
										$AlterSchemaOwner = ""
										$DropSchema = ""
										
										foreach ($sch in $Schemas) {
                                            <#
                                                On sql server 2008 or lower the EnumObjects method does not accept empty parameter.
                                                0x1FFFFFFF is the way we can say we want everything known by those versions

                                                When it is an higer version we can use empty to get all
                                            #>
											if ($server.versionMajor -lt 11) {
												$NumberObjects = ($db.EnumObjects(0x1FFFFFFF) | Where-Object { $_.Schema -eq $sch.Name } | Measure-Object).Count
											}
											else {
												$NumberObjects = ($db.EnumObjects() | Where-Object { $_.Schema -eq $sch.Name } | Measure-Object).Count
											}
											
											if ($NumberObjects -gt 0) {
												if ($Force) {
													Write-Message -Level Verbose -Message "Parameter -Force was used! The schema '$($sch.Name)' have $NumberObjects underlying objects. We will change schema owner to 'dbo' and drop the user."
													
													if ($Pscmdlet.ShouldProcess($db.Name, "Changing schema '$($sch.Name)' owner to 'dbo'. -Force used.")) {
														$AlterSchemaOwner += "ALTER AUTHORIZATION ON SCHEMA::[$($sch.Name)] TO [dbo]`r`n"
														
														[pscustomobject]@{
															Instance = $server.Name
															Database = $db.Name
															SchemaName = $sch.Name
															Action = "ALTER OWNER"
															SchemaOwnerBefore = $sch.Owner
															SchemaOwnerAfter = "dbo"
														}
													}
												}
												else {
													Write-Message -Level Warning -Message "Schema '$($sch.Name)' owned by user $($dbuser.Name) have $NumberObjects underlying objects. If you want to change the schemas' owner to 'dbo' and drop the user anyway, use -Force parameter. Skipping user '$dbuser'"
													$SkipUser = $true
													break
												}
											}
											else {
												if ($sch.Name -eq $dbuser.Name) {
													Write-Message -Level Verbose -Message "The schema '$($sch.Name)' have the same name as user $dbuser. Schema will be dropped."
													
													if ($Pscmdlet.ShouldProcess($db.Name, "Dropping schema '$($sch.Name)'.")) {
														$DropSchema += "DROP SCHEMA [$($sch.Name)]"
														
														[pscustomobject]@{
															Instance = $server.Name
															Database = $db.Name
															SchemaName = $sch.Name
															Action = "DROP"
															SchemaOwnerBefore = $sch.Owner
															SchemaOwnerAfter = "N/A"
														}
													}
												}
												else {
													Write-Message -Level Warning -Message "Schema '$($sch.Name)' does not have any underlying object. Ownership will be changed to 'dbo' so the user can be dropped. Remember to re-check permissions on this schema!"
													
													if ($Pscmdlet.ShouldProcess($db.Name, "Changing schema '$($sch.Name)' owner to 'dbo'.")) {
														$AlterSchemaOwner += "ALTER AUTHORIZATION ON SCHEMA::[$($sch.Name)] TO [dbo]`r`n"
														
														[pscustomobject]@{
															Instance = $server.Name
															Database = $db.Name
															SchemaName = $sch.Name
															Action = "ALTER OWNER"
															SchemaOwnerBefore = $sch.Owner
															SchemaOwnerAfter = "dbo"
														}
													}
												}
											}
										}
										
									}
									else {
										Write-Message -Level Verbose -Message "User $dbuser does not own any schema. Will be dropped."
									}
									
									$query = "$AlterSchemaOwner `r`n$DropSchema `r`nDROP USER " + $dbuser
									
									Write-Message -Level Debug -Message $query
								}
								else {
									$query = "EXEC master.dbo.sp_droplogin @loginame = N'$($dbuser.name)'"
								}
								
								if ($ExistLogin) {
									if (-not $SkipUser) {
										if ($Force) {
											if ($Pscmdlet.ShouldProcess($db.Name, "Dropping user $dbuser using -Force")) {
												$server.Databases[$db.Name].ExecuteNonQuery($query) | Out-Null
												Write-Message -Level Verbose -Message "User $dbuser was dropped from $($db.Name). -Force parameter was used!"
											}
										}
										else {
											Write-Message -Level Warning -Message "Orphan user $($dbuser.Name) has a matching login. The user will not be dropped. If you want to drop anyway, use -Force parameter."
											Continue
										}
									}
								}
								else {
									if (-not $SkipUser) {
										if ($Pscmdlet.ShouldProcess($db.Name, "Dropping user $dbuser")) {
											$server.Databases[$db.Name].ExecuteNonQuery($query) | Out-Null
											Write-Message -Level Verbose -Message "User $dbuser was dropped from $($db.Name)."
										}
									}
								}
							}
						}
						else {
							Write-Message -Level Verbose -Message "No orphan users found on database $db."
						}
						#reset collection
						$User = $null
					}
					catch {
						Write-Message -Level Error -Message $_
					}
				}
			}
			else {
				Write-Message -Level Verbose -Message "There are no databases to analyse."
			}
		}
	}
	
	END {
		
		$totaltime = $start.Elapsed
		
		#If the call don't come from Repair-DbaOrphanUser function, show elapsed time
		if ($StackSource -ne "Repair-DbaOrphanUser") {
			Write-Message -Level Verbose -Message "Total Elapsed time: $totaltime"
		}
		
		Test-DbaDeprecation -DeprecatedOn "1.0.0" -Silent:$false -Alias Remove-SqlOrphanUser
	}
}