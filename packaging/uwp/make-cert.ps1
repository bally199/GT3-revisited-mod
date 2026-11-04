# Makes the self-signed certificate that signs the UWP (Xbox Dev Mode) package: docs/dev/XBOX.md.
#   powershell -ExecutionPolicy Bypass -File packaging/uwp/make-cert.ps1 [-Out gt3r-dev.pfx] [-Password <pw>]
# Writes the .pfx (pass it to CMake as GT3R_UWP_CERT) and the .cer beside it. Never commit them.
# The subject must equal the manifest's Publisher (GT3R_UWP_PUBLISHER, default CN=GT3Revisited-Dev).
param(
    [string]$Out = "gt3r-dev.pfx",
    [string]$Subject = "CN=GT3Revisited-Dev",
    [string]$Password = "gt3r"
)
$ErrorActionPreference = "Stop"
$cert = New-SelfSignedCertificate -Type Custom -Subject $Subject -KeyUsage DigitalSignature `
    -FriendlyName "GT3 Revisited dev signing" -CertStoreLocation "Cert:\CurrentUser\My" `
    -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}") -NotAfter (Get-Date).AddYears(5)
$secure = ConvertTo-SecureString -String $Password -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath $Out -Password $secure | Out-Null
Export-Certificate -Cert $cert -FilePath ([IO.Path]::ChangeExtension($Out, ".cer")) | Out-Null
Write-Host "Wrote $Out and $([IO.Path]::ChangeExtension($Out, '.cer')) for $Subject (thumbprint $($cert.Thumbprint))"
