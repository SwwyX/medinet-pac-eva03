"""Crea o consulta un paciente de prueba en el FQDN (verifica persistencia en el failover).

Uso:
    python tools/paciente.py crear  https://FQDN   (guarda el RUN creado en tools/run_failover.txt)
    python tools/paciente.py buscar https://FQDN   (busca ese RUN)

El token se lee de la variable de entorno PAC_TOKEN y nunca se imprime.
Secuencia del failover: crear -> failover.py + detener un servidor -> buscar.
"""
import json
import os
import pathlib
import sys
from datetime import datetime

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from attack import patient, random_run, request  # noqa: E402

if len(sys.argv) != 3 or sys.argv[1] not in ("crear", "buscar"):
    raise SystemExit(__doc__)

modo, base = sys.argv[1], sys.argv[2].rstrip("/")
token = os.environ["PAC_TOKEN"]
archivo = pathlib.Path(__file__).with_name("run_failover.txt")
api = base + "/patients"

if modo == "crear":
    run = random_run()
    datos = patient(run, nombres="Persistencia", apellido_paterno="Failover")
    status, body, node = request("POST", api, token, datos)
    archivo.write_text(run, encoding="utf-8")
    pid = json.loads(body).get("id") if status == 201 else None
    print(f"{datetime.now():%H:%M:%S}  POST /patients  RUN={run}  -> HTTP {status}  id={pid}  nodo={node}")
else:
    run = archivo.read_text(encoding="utf-8").strip()
    status, body, node = request("GET", f"{api}?run={run}", token)
    total = json.loads(body).get("total") if status == 200 else "?"
    print(f"{datetime.now():%H:%M:%S}  GET /patients?run={run}  -> HTTP {status}  encontrados={total}  nodo={node}")
