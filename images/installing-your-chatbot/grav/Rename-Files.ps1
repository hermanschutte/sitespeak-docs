# Run this script inside the folder containing your files
# Example: open PowerShell, cd into the folder, then run: .\Rename-Files.ps1

Get-ChildItem -File | ForEach-Object {
    $oldName = $_.Name

    # Apply replacements
    $newName = $oldName `
        -replace " - ", "-" `
        -replace "- ", "-" `
        -replace " -", "-" `
        -replace "\. ", "-" `
        -replace " ", "-"   # Replace all spaces with hyphens

    # Only rename if the name actually changed
    if ($newName -ne $oldName) {
        Rename-Item -Path $_.FullName -NewName $newName
        Write-Host "Renamed: $oldName -> $newName"
    }
}