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
