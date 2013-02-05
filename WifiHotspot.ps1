<#
.SYNOPSIS

	Script to turn your PC's Wifi adapter into a personal hotspot that shares your PC's Internet connection.
	This allows you to connect additional WIFI devices to your network without requiring a wireless router 
	or access point. Basically, your PC will act as the WIFI router :-)

	This is handy when your only connection point is wired and you want to also connect a WIFI device such 
	as your mobile phone or tablet,	or when depite having WIFI available, the network only allows one device 
	per user. 
	
	These are common scenarios when on the move and stying in hotels.

	NOTE:	This functionality is only supported on Win 7 and later, and only by certain Wifi adapters. 
		The script will check if your adapter is supported.

.EXAMPLE

	WifiHotspot start
	WifiHotspot stop
	WifiHotspot show

.AUTHOR
	Hector Molina
	donhector@gmail.com

.VERSION
	1.0

.CHANGELOG
	1.0 - 2013/02/04 Initial release

#>

Param
(
	[Parameter(Position = 0)]
	[ValidateSet("start","stop", "show")]
	[string]
	$command = "start"
)


###############
# Functions
###############

Function CheckAdminCredentials
{
	$isAdmin =  ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
	if(-not($isAdmin))
	{
		Write-Warning "This script requires administrator rights to run."
		Write-Warning "You can right click on the script and select 'Run as Administrator...'"
		Write-Warning "Alternatively start a PowerShell console as Administrator and launch the script from there."
		Exit
	}
}

Function CheckAdapterSupport
{
	# Checking if the adapter supports hosted network
	Write-Host "Checking if your Wifi adapter supports hotspot mode... " -nonewline
	$supported = netsh wlan show drivers | Select-String "Hosted network supported" | Select-String "Yes"
	if (!$supported) { Write-Host "Unsupported!" -foregroundcolor red; Exit;}
	Write-Host "Supported!"  -foregroundcolor green
}

Function ConfigureHostedNetwork
{
	# Configuring the hosted network
	Write-Host "Enter hotspot details: SSID (username field) and encryption key (password field)"
	Try { $credentials = Get-Credential -credential "MyWifiHotspot" }
	Catch { Write-Host "Error: Hotspot details window cancelled by user!" -foregroundcolor red; Exit;}
	$ssid = $credentials.GetNetworkCredential().UserName
	$key = $credentials.GetNetworkCredential().Password
	if (!$ssid -or ($ssid.Length -le 2)) { Write-Host "Error: Invalid SSID length. It should be 3 or more characters long!" -foregroundcolor red; Exit;}
	if (!$key -or ($key.Length -le 7)) { Write-Host "Error: Invalid key lenght. It should be 8 or more characters long!" -foregroundcolor red; Exit;}
	Write-Host "Hotspot details ok!`n" -foregroundcolor green
	Write-Host "Configuring hosted network..."
	netsh wlan set hostednetwork mode=allow ssid=$ssid key=$key keyUsage=persistent
}

Function GetNetworkAdapterList
{
	# Get a list of available Adapters
	$hnet = New-Object -ComObject HNetCfg.HNetShare
	$netAdapters = @()
	foreach ($i in $hnet.EnumEveryConnection)
	{
		$netconprop = $hnet.NetConnectionProps($i)
		$inetconf = $hnet.INetSharingConfigurationForINetConnection($i)

		$netAdapters += New-Object PSObject -Property @{
				Index = $index
				Guid = $netconprop.Guid
				Name = $netconprop.Name
				DeviceName = $netconprop.DeviceName
				Status = $netconprop.Status
				MediaType = $netconprop.MediaType
				Characteristics = $netconprop.Characteristics
				SharingEnabled = $inetconf.SharingEnabled
				SharingConnectionType = $inetconf.SharingConnectionType
				InternetFirewallEnabled = $inetconf.InternetFirewallEnabled
				SharingConfigurationObject = $inetconf
				}
		$index++
	}
	return $netAdapters
}

Function GetPublicAdapter($netAdapterListParam)
{
	# Get the adapter that is currently connected (status = 2) to the Internet so it can share its connection
	# This adapter will be used as the public network connection when setting up ICS.
	# As there is no easy way to get which adapter is providing
	# Internet connectivity (there could be more than 1) we ask the user.
	Write-host
	$indexList = @()
	$netAdapterListParam | where { $_.Status -eq '2'} | % {$indexList += $_.Index}
	$filteredList = $netAdapterListParam | where { $_.Status -eq '2'}
	$formatted = $filteredList | fl Name, DeviceName, Index | Out-String
	Write-Host "The following network adapters seem to be enabled on the system:"
	Write-Host $formatted
	$userIndex = Read-Host "Enter the index of the adapter that is providing you Internet connection"
	While ($indexList -notcontains $userIndex)
	{
		Write-Warning "Provided index is invalid! Choose one from the displayed list."
		$userIndex = Read-Host "Enter the index of the adapter that is providing you Internet connection"
	}
	$publicAdapter = $netAdapterListParam[$userIndex]
	return $publicAdapter
}

Function GetPrivateAdapter($netAdapterListParam)
{
	# Get the adapter that will act as the hotspot (i.e. the Virtual Wifi Mini Port adapter)
	# This will be our private network connection when setting up Internet Connection Sharing (ICS).
	[string]$virtualWifiAdapterGUID = Get-WMIObject win32_networkadapterconfiguration | where {$_.ServiceName -eq "vwifimp"} | % {$_.GetRelated('win32_networkadapter')} | Select -ExpandProperty Guid
	# Now get the adapter that matches that GUID from our list of adapters.
	$privateAdapter = $netAdapterListParam | where { $_.Guid -eq $virtualWifiAdapterGUID}
	return $privateAdapter
}

Function StartHostedNetwork
{
	Write-Host "Starting hosted network... " -nonewline
	netsh wlan start hostednetwork | out-null
	Write-Host "Started!" -foregroundcolor green
}

Function StopHostedNetwork
{
	Write-Host "Stopping hosted network... " -nonewline
	netsh wlan set hostednetwork mode=disallow | out-null
	netsh wlan stop hostednetwork | out-null
	Write-Host "Stopped!" -foregroundcolor red
}

Function StartICS($publicAdapter, $privateAdapter)
{
	$public = 0
	$private = 1
	# Enabling Internet Connection Sharing (ICS) on the public connection via the the internal private adapter
	Write-Host "Starting ICS on the selected adapter... " -nonewline
	If($publicAdapter.SharingEnabled -eq $false) { $publicAdapter.SharingConfigurationObject.EnableSharing($public) }
	If($privateAdapter.SharingEnabled -eq $false) { $privateAdapter.SharingConfigurationObject.EnableSharing($private) }
	Write-Host "Started!" -foregroundcolor green
}

Function StopICS ($adapterList)
{
	# Disabling Internet Connection Sharing (ICS) on ALL adapters
	Write-Host "Stopping ICS... " -nonewline
	ForEach ($adapter in $adapterList)
	{
		If($adapter.SharingEnabled -eq $true)
		{
			$adapter.SharingConfigurationObject.DisableSharing()
			#Write-Host "`t-> Disabled sharing on '$($adapter.Name)'" -foregroundcolor green
		}
	}
	Write-Host "Stopped!" -foregroundcolor red
}

###############
# Code Logic
###############

Write-Host "#############################"
Write-Host "    Wifi Hotspot script     "
Write-Host "#############################"

if ($command -eq "show")
{
	netsh wlan show hostednetwork
}
elseif ($command -eq "stop")
{
	CheckAdminCredentials
	$netAdapterList = GetNetworkAdapterList
	StopICS $netAdapterList
	StopHostedNetwork
}
else
{
	CheckAdminCredentials
	CheckAdapterSupport
	ConfigureHostedNetwork
	$netAdapterList = GetNetworkAdapterList
	StartHostedNetwork
	$publicAdapter = GetPublicAdapter $netAdapterList	# The adapter with Inet connection
	$privateAdapter = GetPrivateAdapter $netAdapterList	 # The virtual wifi adapter that creates the hotspot
	StartICS $publicAdapter $privateAdapter
	Write-Host "Hotspot setup is now complete."
	Write-Host "Kindly allow a couple of minutes for the hostspot to show up :-)"
}
