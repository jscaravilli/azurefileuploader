# ---------- CONFIG ----------
$storageAccount = "stortestfiles512351"
$shareName      = "test"
$localFile      = "C:\test\myfile4.txt"
$resource       = "https://storage.azure.com/"
$imdsVer        = "2021-02-01"
$apiVersion     = "2023-11-03"

# ---------- 1. Get User-Assigned Managed Identity Client ID ----------
# Query IMDS for identity info - this returns details about assigned identities
$identityUri = "http://169.254.169.254/metadata/identity/info?api-version=$imdsVer"
try {
    $identityInfo = Invoke-RestMethod -Uri $identityUri -Headers @{ Metadata = "true" } -Method GET -ErrorAction Stop
    
    # The response contains clientId field(s) for user-assigned identities
    # It may be a single object or an array if multiple identities exist
    if ($identityInfo.clientId) {
        $clientId = $identityInfo.clientId
        Write-Host "Using User-Assigned MI: $clientId"
    } elseif ($identityInfo[0].clientId) {
        $clientId = $identityInfo[0].clientId
        Write-Host "Using first User-Assigned MI: $clientId"
    } else {
        # Fallback to known client ID if IMDS structure is different
        $clientId = "f00086e1-7361-48b4-94fd-1d3899eb421e"
        Write-Host "Using configured User-Assigned MI: $clientId"
    }
} catch {
    Write-Host "⚠️ Could not query IMDS, using configured client ID"
    $clientId = "f00086e1-7361-48b4-94fd-1d3899eb421e"
}

# ---------- 2. Build Storage URI from filename ----------
$fileName = Split-Path $localFile -Leaf
$storageUri = "https://$storageAccount.file.core.windows.net/$shareName/$fileName"
Write-Host "Target URI: $storageUri"

# ---------- 3. Get Token ----------
$tokenUri = "http://169.254.169.254/metadata/identity/oauth2/token?resource=$resource&client_id=$clientId&api-version=$imdsVer"
$token = (Invoke-RestMethod -Uri $tokenUri -Headers @{ Metadata = "true" } -Method GET).access_token

# ---------- 4. Read File + Hash ----------
$fileBytes = [System.IO.File]::ReadAllBytes($localFile)
$fileLength = $fileBytes.Length
$localHash = [System.BitConverter]::ToString((New-Object System.Security.Cryptography.SHA256Managed).ComputeHash($fileBytes)).Replace("-", "").ToLower()
Write-Host "Local SHA256: $localHash"

# ---------- 5. Create Empty File ----------
$createHeaders = @{
    "Authorization"           = "Bearer $token"
    "x-ms-version"            = $apiVersion
    "x-ms-type"               = "file"
    "x-ms-content-length"     = "$fileLength"
    "x-ms-file-request-intent" = "backup"
    "Content-Length"          = "0"
}
Invoke-RestMethod -Uri $storageUri -Method PUT -Headers $createHeaders -ErrorAction Stop | Out-Null

# ---------- 4. Upload File Content ----------
$uploadHeaders = @{
    "Authorization"           = "Bearer $token"
    "x-ms-version"            = $apiVersion
    "x-ms-write"              = "update"
    "x-ms-range"              = "bytes=0-$($fileLength - 1)"
    "x-ms-file-request-intent" = "backup"
    "Content-Length"          = "$fileLength"
}
$uploadUri = "$storageUri`?comp=range"
Invoke-RestMethod -Uri $uploadUri -Method PUT -Headers $uploadHeaders -Body $fileBytes -ContentType "application/octet-stream" -ErrorAction Stop | Out-Null

# ---------- 5. Verify Upload (Download + Hash) ----------
$tempPath = "$env:TEMP\azureverify.tmp"
Invoke-RestMethod -Uri $storageUri -Method GET -Headers @{ Authorization = "Bearer $token"; "x-ms-version" = $apiVersion; "x-ms-file-request-intent" = "backup" } -OutFile $tempPath
$downloadedBytes = [System.IO.File]::ReadAllBytes($tempPath)
$remoteHash = [System.BitConverter]::ToString((New-Object System.Security.Cryptography.SHA256Managed).ComputeHash($downloadedBytes)).Replace("-", "").ToLower()
Remove-Item $tempPath -Force

# ---------- 6. Compare Hashes ----------
if ($remoteHash -eq $localHash) {
    Write-Host "`n✅ Upload verified successfully!" -ForegroundColor Green
} else {
    Write-Host "`n❌ WARNING: Hash mismatch!" -ForegroundColor Red
}
