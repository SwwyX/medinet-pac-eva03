# Guía de presentación EVA03 · Módulo PAC (Grupo 6)

Demo de unos 12 minutos, siguiendo el orden de la rúbrica. Cada bloque dice **qué abrir**, **qué decir** y **qué responder si el profe pregunta**.

> **El día antes:** despliega con el `README.md` (pasos 1 a 6), prueba todo una vez y deja abiertas las pestañas de la lista de abajo.
> **Después de presentar:** `terraform destroy`.

## Pestañas listas antes de empezar
1. GitHub: el repositorio y la pestaña **Actions** con la última ejecución en verde.
2. VS Code con la carpeta `infra/` abierta.
3. Consola AWS: **EC2 → Instancias**, **EC2 → Target groups**, **RDS**, **EC2 → Security Groups**, **CloudWatch → Log groups → /medinet-pac/app**.
4. Navegador en `https://TU-FQDN/docs`.
5. Dos terminales PowerShell en la carpeta del proyecto, con un token ya generado:
   ```powershell
   $T = python tools\dev_token.py
   $R = python tools\dev_token.py --roles pac:read
   ```

---

## 1. Infraestructura como código (criterio 1) · 2 min
**Muestra:** la carpeta `infra/` y abre `security_groups.tf`.

**Di:** "Toda la infraestructura está en Terraform: la VPC con subredes en 2 zonas, las rutas, el NAT, los Security Groups, el ALB, las 2 EC2 y RDS. No creamos nada a mano en la consola. Las contraseñas no están en el repositorio: la de RDS la genera AWS en Secrets Manager y las demás quedan en SSM cifradas con nuestra llave KMS."

**Muestra:** GitHub → Actions → la ejecución → job **iac-scan**.

**Di:** "Antes de desplegar, el pipeline pasa Checkov sobre el Terraform: 198 controles aprobados y 0 fallidos. Si alguien sube una mala configuración, el pipeline se bloquea."

| Si pregunta… | Responde |
|---|---|
| ¿Por qué hay controles omitidos? | Son 6 y cada uno está justificado en el código: por ejemplo el WAF, por costo, y el puerto 80, que solo redirige a HTTPS. |
| ¿Dónde están las contraseñas? | En Secrets Manager y SSM, cifradas con KMS. Las EC2 las leen al arrancar y las dejan en memoria, nunca en disco. |
| ¿Cómo funciona en AWS Academy? | Con `aws_academy = true`, Terraform no crea roles y usa `LabRole` y `LabInstanceProfile`. |

## 2. Arquitectura Multi-AZ (criterio 2) · 3 min
**Muestra:** la Figura 1 del informe y después la consola.
- **EC2:** "2 instancias, una en cada zona, **sin IP pública**, ejecutando los contenedores endurecidos del backend (8000) y del frontend (8080)."
- **Target groups:** "Los 2 grupos de destino (API en `/health` y frontend en `/healthz`) tienen sus 2 nodos *healthy*. El ALB revisa cada 5 segundos."
- **Navegador `https://TU-FQDN/` y `https://TU-FQDN/docs`:** haz clic en el candado. "Certificado válido de Amazon, sin advertencias; en `/` responde el frontend de admisión y en `/docs` la documentación interactiva Swagger."
- **Terminal:**
  ```powershell
  curl.exe -I http://TU-FQDN/health
  ```
  "HTTP responde 301 y redirige a HTTPS."
- **RDS:** "*Publicly accessible: No*, *Encryption: Enabled*, subnet group en 2 zonas."
- **Security Groups:** abre `sg-app` → *Inbound rules*. "El origen no es una IP, es el Security Group del ALB (puertos 8000 y 8080). Y en `sg-db` el origen es `sg-app` (puerto 5432). Eso es el encadenamiento."

| Si pregunta… | Responde |
|---|---|
| ¿Puedo entrar directo a una EC2? | No: no tienen IP pública, están en subredes privadas y solo aceptan el puerto 8000 desde el ALB. Se administran con Session Manager, sin SSH. |
| ¿Qué pasa si se cae una zona? | El otro nodo sigue atendiendo contra la misma RDS. Lo muestro en el failover. |
| ¿Por qué un solo NAT? | Por costo. Si cae la zona a, el servicio sigue funcionando; solo se pierde la salida a Internet para nuevos despliegues. |

## 3. Protección de datos y lógica del módulo (criterio 3) · 3 min
**En Swagger:** prueba `GET /patients` **sin** token y muestra el **401**. Luego presiona **Authorize**, pega `$T` y crea un paciente con `POST /patients`.
```json
{"run": "12.345.678-5", "nombres": "Ana", "apellido_paterno": "Muñoz", "fecha_nacimiento": "1990-05-10", "prevision": "FONASA"}
```
Presiona **F12 → Network** y muestra las cabeceras de la respuesta: `strict-transport-security`, `x-frame-options`, `x-content-type-options`, `content-security-policy` y `cache-control: no-store`.

**CloudWatch → /medinet-pac/app:** "Cada lectura y escritura deja un evento de auditoría con quién, cuándo y qué paciente, con el RUN enmascarado: `******78-5`. Nunca el nombre ni el email."

**Di:** "Con dos nodos en paralelo, que un RUN no se duplique lo garantiza la base de datos con `UNIQUE`, no el código de cada nodo. Y para editar bloqueamos la fila con `FOR UPDATE`."

| Si pregunta… | Responde |
|---|---|
| ¿Cómo se cifra en tránsito? | Cliente a ALB con TLS 1.2/1.3. ALB a EC2 dentro de la VPC privada. EC2 a RDS con TLS obligatorio (`rds.force_ssl`) y verificando el certificado de RDS (`verify-full`). |
| ¿Y en reposo? | RDS, los discos, los secretos y los logs están cifrados con nuestra llave KMS, que rota cada año. |
| ¿Quién emite el JWT? | El módulo IAM. PAC solo lo verifica: firma, emisor, audiencia, expiración y rol. |

## 4. Pruebas en ambiente controlado (criterio 4) · 4 min
**a) Ataque controlado**
```powershell
python tools\attack.py https://TU-FQDN --token $T --readonly-token $R
```
"50 altas simultáneas del mismo RUN repartidas entre los 2 nodos: solo 1 se crea. También probamos inyección SQL, XSS, tokens manipulados y escalada de privilegios: 13 de 13 bloqueados. En la primera ejecución encontramos un XSS almacenado y lo corregimos."

**b) Failover (en vivo)**
```powershell
python tools\failover.py https://TU-FQDN --token $T
```
Mientras corre, en la consola: **EC2 → node-a → Estado de la instancia → Detener**. "Fíjense en la columna `nodo`: pasa a responder solo `node-b` y no se cae el servicio." Termina con **Ctrl+C** para ver el resumen de disponibilidad. Después **vuelve a iniciar node-a**.

**c) DAST con OWASP ZAP:** abre `evidence\zap-report.html`, generado el día antes con `tools\zap_scan.ps1`. "Escaneamos el FQDN por HTTPS y corregimos lo que encontró."

## 5. Informe (criterio 5) · 1 min
Muestra el índice del informe: diagrama, STRIDE, Checkov, ZAP y la comparación con la Ley 20.584, la Ley 19.628/21.719, HIPAA, HL7 FHIR e ISO 27799.

**Frase de cierre:** "Las cinco normas piden lo mismo en lo técnico: cifrado, control de acceso, minimización y trazabilidad. Implementamos las cuatro y las probamos atacándolas."

---

## Si algo falla en vivo
| Problema | Qué hacer |
|---|---|
| 502 o 503 en la URL | El nodo aún arranca. Espera 1 minuto y revisa *Target group → Targets*. |
| 401 con el token | El token expiró (dura 30 minutos). Genera otro con `python tools\dev_token.py`. |
| El certificado no carga | La delegación NS no se propagó. Muestra el ALB por su DNS de AWS y explica que el FQDN depende del DNS. |
| La sesión de AWS Academy expiró | Vuelve a iniciar el lab: las EC2 se reinician solas y la API vuelve sola gracias al servicio `pac-deploy`. |
