$engine = docker info --format '{{.OSType}}' 2>$null
if ($engine -ne 'windows') {
    # GitHub-hosted Windows runners sometimes boot without a working Docker
    # pipe; restarting the installed service recovers it.
    Restart-Service docker -ErrorAction Stop
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 2
        $engine = docker info --format '{{.OSType}}' 2>$null
        if ($engine -eq 'windows') { break }
    }
}
if ($engine -ne 'windows') {
    throw 'Windows container engine is unavailable'
}
$ErrorActionPreference = 'Stop'

$candidate = "${env:IMAGE}:build-${env:GITHUB_RUN_ID}-${env:GITHUB_RUN_ATTEMPT}-${env:BASE}"
docker build --pull --memory 2GB -f windows/Dockerfile --build-arg "BASE_IMAGE=$env:BASE_IMAGE" --build-arg "MOONBIT_VERSION=$env:VERSION" -t $candidate .
if ($LASTEXITCODE -ne 0) { throw 'Windows image build failed' }

docker run --rm $candidate cmd /S /C C:\smoke.cmd
if ($LASTEXITCODE -ne 0) { throw 'Windows smoke test failed' }

# Docker's Windows builder does not provide build-push-action's digest output.
# Push only after the local smoke test, then export the registry digest used by
# the common tag publisher. The build tag is unique to this workflow attempt.
docker push $candidate
if ($LASTEXITCODE -ne 0) { throw 'Windows image push failed' }
$repoDigest = (docker image inspect $candidate --format '{{index .RepoDigests 0}}').Trim()
if ($LASTEXITCODE -ne 0 -or $repoDigest -notmatch '@sha256:[0-9a-f]{64}$') {
    throw 'Cannot find pushed Windows image digest'
}
$digest = $repoDigest.Substring($repoDigest.LastIndexOf('@') + 1)
$directory = Join-Path $env:RUNNER_TEMP "digests/$env:BASE"
New-Item -ItemType Directory -Force -Path $directory | Out-Null
Set-Content -Path (Join-Path $directory 'amd64.digest') -Value $digest -NoNewline
