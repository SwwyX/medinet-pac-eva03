# MediNet-Core · Módulo PAC 

Grupo 6 · Desarrollo Seguro (CI3064) 

Frontend y API de pacientes desplegados en AWS en alta disponibilidad (2 zonas), creados con Terraform.

## Carpetas

- `app/` código de la API (FastAPI)
- `frontend/` página de admisión (registro con validación de RUN, búsqueda paginada) servida por nginx sin privilegios
- `infra/` infraestructura en Terraform
- `tests/` pruebas
- `tools/` ataque controlado, failover, escaneo ZAP y tokens de prueba
- `docs/` evidencias

## Desplegar

```bash
cd infra
terraform init
terraform apply
```

## Apagar

```bash
terraform destroy
```

## Arquitectura

`Usuario → https://medinetpacg6.dpdns.org → ALB (443) → Auto Scaling Group (2 a 4 EC2 en us-east-2a y 2b, sin IP pública) → RDS PostgreSQL privada y cifrada`

- **ALB**: HTTPS con certificado ACM (TLS 1.2 y 1.3), el puerto 80 redirige con 301; health checks cada 5 s a la API (`/health`) y a la página (`/healthz`).
- **Auto Scaling** (`infra/autoscaling.tf`): Launch Template + Auto Scaling Group (mínimo 2, máximo 4) + política de CPU al 50 %. Si un servidor falla, el grupo lo reemplaza solo.
- **Security Groups encadenados**: internet → ALB (80/443) → app (8000/8080, solo desde el ALB) → base (5432, solo desde app).
- **Cifrado**: TLS en tránsito; discos y RDS cifrados en reposo con KMS; secretos en Secrets Manager y SSM.

## Seguridad aplicada

JWT con roles (`pac:read`, `pac:write`), validación estricta (Pydantic), `UNIQUE(run)` contra la condición de carrera, usuario de base de datos con mínimo privilegio, cabeceras HSTS / nosniff / X-Frame-Options / CSP, CORS restrictivo, errores sin stack trace y auditoría en CloudWatch con el RUN enmascarado.
Pipeline (`.github/workflows/ci-cd.yml`): pytest, Bandit (SAST), Checkov (IaC) y Trivy en cada push.

## Herramientas de prueba (`tools/`)

| Archivo | Para qué sirve | Ejemplo |
|---|---|---|
| `dev_token.py` | Genera el JWT de prueba (como lo emitiría IAM) | `python tools/dev_token.py --region us-east-2 --minutes 180` |
| `attack.py` | Ataque controlado: carrera de 50 altas con el mismo RUN, SQLi, XSS, tokens falsos, escalada de privilegios (13 pruebas) | `python tools/attack.py $U --token $T --readonly-token $R` |
| `failover.py` | Consultas continuas al sitio mientras se detiene un servidor | `python tools/failover.py $U --token $T` |
| `paciente.py` | Crea y busca un paciente para comprobar que no se pierden datos en el failover | `python tools/paciente.py crear $U` |
| `zap_scan.ps1` | Escaneo dinámico con OWASP ZAP contra el dominio (PowerShell + Docker) | `.\tools\zap_scan.ps1 -Url $U` |
| `levantar_local.ps1` | Levanta toda la aplicación en un PC con Docker (PowerShell) | `.\tools\levantar_local.ps1` |

Secuencia del failover: `paciente.py crear` → `failover.py` en una terminal → detener un servidor EC2 → `paciente.py buscar`.
Resultados: ataque 13/13 bloqueados, failover 265/265 respuestas correctas con Auto Scaling, Checkov 196 aprobados y 0 fallidos.
