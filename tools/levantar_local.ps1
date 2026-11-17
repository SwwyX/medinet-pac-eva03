# Levanta TODA la aplicacion PAC en este PC con un solo comando (plan B local).
# Si Docker Desktop esta cerrado, lo abre y espera a que el motor este listo.
# Uso:    powershell -ExecutionPolicy Bypass -File tools\levantar_local.ps1
# Apagar: powershell -ExecutionPolicy Bypass -File tools\levantar_local.ps1 -Apagar
param([switch]$Apagar)

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path $PSScriptRoot)
$S = Join-Path $env:TEMP 'pacsec'
function Paso($t) { Write-Host "`n==> $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "    OK  $t" -ForegroundColor Green }
function Falla($t){ Write-Host "    ERROR  $t" -ForegroundColor Red; exit 1 }
function DockerListo { docker info --format '{{.ServerVersion}}' *> $null; return ($LASTEXITCODE -eq 0) }

if ($Apagar) {
    Paso 'Apagando la aplicacion local'
    docker rm -f pacproxy pacfront pacapi pacdb *> $null
    docker network rm pacnet *> $null
    Remove-Item -Recurse -Force $S -ErrorAction SilentlyContinue
    Ok 'Contenedores, red y secretos temporales borrados'
    exit 0
}

# 1) Docker
Paso '1/7 Docker Desktop'
if (-not (DockerListo)) {
    Write-Host '    Docker esta cerrado: lo abro yo...'
    docker desktop start *> $null
    if ($LASTEXITCODE -ne 0) {
        $exe = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
        if (Test-Path $exe) { Start-Process $exe } else { Falla 'No encuentro Docker Desktop. Instalalo (winget install -e --id Docker.DockerDesktop).' }
    }
    $t0 = Get-Date
    while (-not (DockerListo)) {
        if (((Get-Date) - $t0).TotalSeconds -gt 240) { Falla 'Docker no arranco en 4 minutos. Abrelo a mano y vuelve a correr este script.' }
        Start-Sleep 5; Write-Host '    ...esperando el motor de Docker'
    }
}
Ok "Docker listo (version $(docker info --format '{{.ServerVersion}}'))"

# 2) Python
Paso '2/7 Entorno de Python'
$venv = "$env:USERPROFILE\.pacvenv"
if (-not (Test-Path "$venv\Scripts\python.exe")) {
    Write-Host '    Creando el entorno por primera vez (2-5 min)...'
    python -m venv $venv
    & "$venv\Scripts\python.exe" -m pip install -q -r requirements-dev.txt
}
$py = "$venv\Scripts\python.exe"
& $py -c "import jwt" *> $null
if ($LASTEXITCODE -ne 0) { & $py -m pip install -q -r requirements-dev.txt }
Ok 'Entorno listo'

# 3) Imagenes
Paso '3/7 Construyendo las imagenes (la primera vez tarda unos minutos)'
docker build -q -t medinet-pac:local . | Out-Null;           if ($LASTEXITCODE -ne 0) { Falla 'No se pudo construir la imagen de la API' }
docker build -q -t medinet-pac:front-local frontend | Out-Null; if ($LASTEXITCODE -ne 0) { Falla 'No se pudo construir la imagen del frontend' }
Ok 'medinet-pac:local y medinet-pac:front-local'

# 4) Limpieza de una vez anterior, red y secretos
Paso '4/7 Red privada y secretos'
docker rm -f pacproxy pacfront pacapi pacdb *> $null
docker network create pacnet *> $null
New-Item -ItemType Directory -Force $S | Out-Null
& $py -I -c "import secrets,sys,pathlib;d=pathlib.Path(sys.argv[1]);[(d/n).write_text(secrets.token_urlsafe(40)) for n in ('admin_password','api_password','jwt_secret')]" $S
Ok 'Red pacnet y 3 secretos al azar'

# 5) Base de datos y migraciones
Paso '5/7 Base de datos'
docker run -d --name pacdb --network pacnet -e POSTGRES_DB=pac -e POSTGRES_USER=pacadmin -e POSTGRES_PASSWORD_FILE=/run/secrets/admin_password -v "$S\admin_password:/run/secrets/admin_password:ro" --tmpfs /var/lib/postgresql postgres:17-alpine | Out-Null
$t0 = Get-Date
do { Start-Sleep 2; docker exec pacdb pg_isready -U pacadmin -d pac *> $null } while ($LASTEXITCODE -ne 0 -and ((Get-Date) - $t0).TotalSeconds -lt 60)
if ($LASTEXITCODE -ne 0) { Falla 'PostgreSQL no respondio' }
Start-Sleep 2
docker run --rm --network pacnet --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges:true -e DB_HOST=pacdb -e DB_PORT=5432 -e POSTGRES_DB=pac -e POSTGRES_USER=pacadmin -e PAC_DB_USER=pac_api -v "$S\admin_password:/run/secrets/admin_password:ro" -v "$S\api_password:/run/secrets/api_password:ro" medinet-pac:local admin
if ($LASTEXITCODE -ne 0) { Falla 'Fallaron las migraciones' }
Ok 'PostgreSQL 17 con tablas y usuario pac_api'

# 6) API, frontend y balanceador local
Paso '6/7 API, frontend y balanceador'
docker run -d --name pacapi --network pacnet -p 127.0.0.1:8000:8000 --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges:true -e DB_HOST=pacdb -e DB_PORT=5432 -e POSTGRES_DB=pac -e PAC_DB_USER=pac_api -e PAC_NODE_ID=node-a -v "$S\api_password:/run/secrets/api_password:ro" -v "$S\jwt_secret:/run/secrets/jwt_secret:ro" medinet-pac:local api | Out-Null
docker run -d --name pacfront --network pacnet --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges:true medinet-pac:front-local | Out-Null
docker run -d --name pacproxy --network pacnet -p 127.0.0.1:8080:8080 --read-only --tmpfs /tmp --cap-drop ALL -v "$PWD\frontend\alb-local.conf:/etc/nginx/conf.d/default.conf:ro" nginxinc/nginx-unprivileged:1.29-alpine | Out-Null
$t0 = Get-Date
do { Start-Sleep 2; $code = curl.exe -s -o NUL -w "%{http_code}" http://127.0.0.1:8080/health } while ($code -ne '200' -and ((Get-Date) - $t0).TotalSeconds -lt 60)
if ($code -ne '200') { docker logs --tail 20 pacapi; Falla 'La API no respondio en /health' }
$front = curl.exe -s -o NUL -w "%{http_code}" http://127.0.0.1:8080/
Ok "API /health = 200 - frontend = $front"

# 7) Token
Paso '7/7 Token de acceso (dura 3 horas)'
$env:PAC_JWT_SECRET = (Get-Content "$S\jwt_secret" -Raw).Trim()
$T = & $py tools\dev_token.py --minutes 180
$R = & $py tools\dev_token.py --minutes 180 --roles pac:read
$T | Set-Clipboard
Ok 'Token de admision copiado al portapapeles'

Write-Host "`n  TODO LISTO" -ForegroundColor Green
Write-Host "  Abre http://127.0.0.1:8080 , pega el token (Ctrl+V) en 'Credencial emitida por IAM' y clic en Ingresar."
Write-Host "  Para apagar: powershell -ExecutionPolicy Bypass -File tools\levantar_local.ps1 -Apagar`n"
Start-Process 'http://127.0.0.1:8080'
