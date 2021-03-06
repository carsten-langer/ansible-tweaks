# Configure a Windows host for remote management with Ansible
# -----------------------------------------------------------
#
# This script checks the current WinRM/PSRemoting configuration and makes the
# necessary changes to allow Ansible to connect, authenticate and execute
# PowerShell commands.
# 
# Written by Trond Hindenes <trond@hindenes.com>
# Updated by Chris Church <cchurch@ansible.com>
# Updated by Carsten Langer <carsten.langer@nokia.com> to use an official SSL certificate already loaded e.g. via MMC
#
# Version 1.0 - July 6th, 2014
# Version 1.1 - November 11th, 2014
# Version 1.2 - December 5th, 2015

# Set $VerbosePreference = "Continue" before running the script in order to
# see the output messages.
$VerbosePreference = "Continue"


# Setup error handling.
Trap
{
    $_
    Exit 1
}
$ErrorActionPreference = "Stop"


# Detect PowerShell version. 
If ($PSVersionTable.PSVersion.Major -lt 3) 
{ 
    Throw "PowerShell version 3 or higher is required." 
} 


# Find and start the WinRM service.
Write-Verbose "Verifying WinRM service."
If (!(Get-Service "WinRM"))
{
    Throw "Unable to find the WinRM service."
}
ElseIf ((Get-Service "WinRM").Status -ne "Running")
{
    Write-Verbose "Starting WinRM service."
    Start-Service -Name "WinRM" -ErrorAction Stop
}


# WinRM should be running; check that we have a PS session config.
If (!(Get-PSSessionConfiguration -Verbose:$false) -or (!(Get-ChildItem WSMan:\localhost\Listener)))
{
    Write-Verbose "Enabling PS Remoting."
    Enable-PSRemoting -Force -ErrorAction Stop
}
Else
{
    Write-Verbose "PS Remoting is already enabled."
}


# Make sure there is a SSL listener. Use the certificate uploaded to Cert:\LocalMachine\my.
$listeners = Get-ChildItem WSMan:\localhost\Listener
If (!($listeners | Where {$_.Keys -like "TRANSPORT=HTTPS"}))
{
    # HTTPS-based endpoint does not exist.
    $cert = Get-ChildItem "Cert:\LocalMachine\my"| Sort-Object NotBefore -Descending | Select -First 1
    If (!($cert))
    {
        Throw "Unable to find a certificate in Cert:\LocalMachine\my. Please install a certificate including private key (e.g. as pfx bundle) via MMC."
    }

    If (!($cert.HasPrivateKey))
    {
        Throw "Certificate does not have a private key. Please install a certificate including private key (e.g. as pfx bundle) via MMC."
    }

    $thumbprint = $cert.Thumbprint

    # Create the hashtables of settings to be used.
    $valueset = @{}
    $valueset.Add('Hostname', $cert.Subject.Split(",")[0].Split("=")[1])  # Assume CN=<fqdn> is first entry in subject.
    $valueset.Add('CertificateThumbprint', $thumbprint)

    $selectorset = @{}
    $selectorset.Add('Transport', 'HTTPS')
    $selectorset.Add('Address', '*')

    Write-Verbose "Enabling SSL listener."
    New-WSManInstance -ResourceURI 'winrm/config/Listener' -SelectorSet $selectorset -ValueSet $valueset
}
Else
{
    Write-Verbose "SSL listener is already active."
}


# Check for basic authentication.
$basicAuthSetting = Get-ChildItem WSMan:\localhost\Service\Auth | Where {$_.Name -eq "Basic"}
If (($basicAuthSetting.Value) -eq $false)
{
    Write-Verbose "Enabling basic auth support."
    Set-Item -Path "WSMan:\localhost\Service\Auth\Basic" -Value $true
}
Else
{
    Write-Verbose "Basic auth is already enabled."
}


# Configure firewall to allow WinRM HTTPS connections.
$fwtest1 = netsh advfirewall firewall show rule name="Allow WinRM HTTPS"
$fwtest2 = netsh advfirewall firewall show rule name="Allow WinRM HTTPS" profile=any
If ($fwtest1.count -lt 5)
{
    Write-Verbose "Adding firewall rule to allow WinRM HTTPS."
    netsh advfirewall firewall add rule profile=any name="Allow WinRM HTTPS" dir=in localport=5986 protocol=TCP action=allow
}
ElseIf (($fwtest1.count -ge 5) -and ($fwtest2.count -lt 5))
{
    Write-Verbose "Updating firewall rule to allow WinRM HTTPS for any profile."
    netsh advfirewall firewall set rule name="Allow WinRM HTTPS" new profile=any
}
Else
{
    Write-Verbose "Firewall rule already exists to allow WinRM HTTPS."
}


# Test a remoting connection to localhost, which should work.
$httpResult = Invoke-Command -ComputerName "localhost" -ScriptBlock {$env:COMPUTERNAME} -ErrorVariable httpError -ErrorAction SilentlyContinue
$httpsOptions = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck

$httpsResult = New-PSSession -UseSSL -ComputerName "localhost" -SessionOption $httpsOptions -ErrorVariable httpsError -ErrorAction SilentlyContinue

If ($httpResult -and $httpsResult)
{
    Write-Verbose "HTTP and HTTPS sessions are enabled."
}
ElseIf ($httpsResult -and !$httpResult)
{
    Write-Verbose "HTTP sessions are disabled, HTTPS session are enabled."
}
ElseIf ($httpResult -and !$httpsResult)
{
    Write-Verbose "HTTPS sessions are disabled, HTTP session are enabled."
}
Else
{
    Throw "Unable to establish an HTTP or HTTPS remoting session."
}

Write-Verbose "PS Remoting has been successfully configured for Ansible."
