# docs/PLAN_AWS.md — Extensión AWS: Docker en EC2

## Contexto

Este documento extiende `docs/PLAN.md` (M1–M9, completados) con los milestones M10–M13.

**Objetivo**: correr el proyecto tal cual en una EC2 en AWS, con Docker Compose, múltiples
workers (2 datanodes + 2 nodemanagers) y 3 reducers por job. La demo se graba en video
para la presentación final.

**Pre-requisito**: M1–M9 de `docs/PLAN.md` completos (`git log` lo confirma).

**Budget**: $50 USD (cuenta del profesor). Budget creado con alertas a $10, $25 y $40.

---

## Arquitectura objetivo

```
                        AWS us-east-1
                  ┌──────────────────────────┐
                  │  EC2: m5.xlarge          │
                  │  (4 vCPU, 16 GB RAM)     │
                  │                          │
                  │  Docker Compose          │
                  │  ├── nasa-namenode       │
                  │  ├── nasa-datanode-1     │  :9870  NameNode UI
                  │  ├── nasa-datanode-2     │  :8088  ResourceManager UI
                  │  ├── nasa-resourcemanager│  :19888 HistoryServer UI
                  │  ├── nasa-nodemanager-1  │
                  │  ├── nasa-nodemanager-2  │
                  │  └── nasa-historyserver  │
                  │                          │
                  │  Security Group:         │
                  │  puerto 22  (SSH)        │
                  │  puerto 9870 (NameNode)  │
                  │  puerto 8088 (YARN)      │
                  │  puerto 19888 (History)  │
                  └──────────────────────────┘
```

**Costo estimado**:

| Recurso | Precio/hr | Tiempo | Total |
|---|---|---|---|
| m5.xlarge (4 vCPU, 16 GB) | $0.192 | ~2 hr | ~$0.40 |
| EBS 20 GB gp3 | $0.002 | ~2 hr | $0.00 |
| **Total** | | | **< $1** |

Con $50 puedes correr esto más de 100 veces.

---

## Milestones

---

### Milestone 10 — Docker escalado: 2 datanodes + 2 nodemanagers (local)

Antes de subir a AWS, escalar el proyecto localmente para validar que funciona con
múltiples workers. No gastar nada en AWS hasta que esto esté verificado.

- **Objetivo**: `make up` levanta 2 datanodes + 2 nodemanagers; HDFS replica en ambos
  datanodes; los 3 reducers distribuyen trabajo entre los 2 nodemanagers.
- **Archivos a modificar**:
  - `docker-compose.yml`
  - `hadoop.env`
  - `Makefile` (targets `up`, `verify`)
  - `scripts/verify_cluster.sh`
  - `scripts/load_to_hdfs.sh`
- **Pre-requisitos**: M1–M9 completos.
- **Especificación detallada**:

  **docker-compose.yml**:
  - Quitar `container_name` y `hostname` de `datanode` y `nodemanager` — bloquean `--scale`.
  - Quitar port mappings fijos `9864:9864` y `8042:8042` de `datanode` y `nodemanager`
    (colisionan al escalar). Las UIs de datanode/nodemanager no son necesarias para la demo.
  - Mantener `container_name` fijo solo en: `nasa-namenode`, `nasa-resourcemanager`,
    `nasa-historyserver` (son únicos, sin `--scale`).

  **hadoop.env**:
  - Cambiar `HDFS-SITE.XML_dfs.replication=1` → `HDFS-SITE.XML_dfs.replication=2`.
  - Añadir `MAPRED-SITE.XML_mapreduce.input.fileinputformat.split.maxsize=33554432`
    (32 MB) para forzar ~7 splits y demostrar ≥6 map tasks en paralelo.
  - Añadir `YARN-SITE.XML_yarn.nodemanager.resource.memory-mb=2048`.

  **Makefile — target `up`**:
  - Cambiar a: `docker compose up -d --build --scale datanode=2 --scale nodemanager=2`
  - Reescribir el healthcheck usando `docker compose ps --format json` contando 7
    contenedores healthy (namenode×1 + datanode×2 + resourcemanager×1 + nodemanager×2
    + historyserver×1).

  **scripts/verify_cluster.sh** — reemplazar checks de conteo fijo:
  - `live_datanodes`: `hdfs dfsadmin -report` muestra `Live datanodes (2)`.
  - `nodemanagers`: `yarn node -list 2>/dev/null | grep -c RUNNING` ≥ 2.
  - `replication_factor`: tras load, `hdfs fsck` muestra `Average block replication: 2.0`.

  **scripts/load_to_hdfs.sh**:
  - Añadir `-D dfs.replication=2` al `hdfs dfs -put`.

  **scripts/run_job.sh**:
  - Añadir segundo argumento: `NUM_REDUCERS=${2:-3}`.
  - Cambiar `-numReduceTasks 1` → `-numReduceTasks $NUM_REDUCERS`.

  **Makefile job-top, job-status**:
  - Actualizar llamadas a `run_job.sh` (sin cambio de interfaz, el default es 3).

- **Comando de verificación**:
  ```bash
  make down && make up && make verify
  make job-top
  # JobHistory en :19888 debe mostrar 3 reduce tasks
  ```
- **Criterio de done**:
  - [ ] `docker compose ps` muestra 7 contenedores healthy.
  - [ ] `make verify` exits 0: `live_datanodes: 2`, `nodemanagers: 2`, replicación 2.0.
  - [ ] `make job-top` produce `part-00000`, `part-00001`, `part-00002` en HDFS.
  - [ ] Output final igual que en M5 (top URL no cambia).
  - [ ] `git status` limpio. Commit: `milestone 10: scale to 2 datanodes + 2 nodemanagers`.

---

### Milestone 11 — Job 3: hourly_traffic

- **Objetivo**: `make job-hourly` produce distribución de requests por hora del día (00–23).
- **Archivos a crear/modificar**:
  - `jobs/hourly_traffic/mapper.py`
  - `jobs/hourly_traffic/combiner.py`
  - `jobs/hourly_traffic/reducer.py`
  - `Makefile` (añadir `job-hourly`; actualizar `results` y `demo`)
  - `tests/test_mappers.py` (añadir tests)
- **Pre-requisitos**: M10.
- **Especificación detallada**:

  **jobs/hourly_traffic/mapper.py**:
  - Misma `LINE_RE` que `top_resources/mapper.py` (copiar deliberadamente).
  - Timestamp en `m.group(2)`, formato `01/Jul/1995:00:00:01 -0400`.
  - Extraer hora: `m.group(2).split(':')[1]` → string `HH` de 2 dígitos.
  - Validar `0 <= int(hour) <= 23`; si no, `reporter:counter:nasa,bad_hour,1`.
  - Emitir `HH\t1` (clave como string `"09"` no `"9"` — orden lexicográfico correcto).

  **jobs/hourly_traffic/combiner.py** y **reducer.py**:
  - Mismo patrón streaming-sum que `top_resources`.
  - Output final: `HH\t<count>`.

  **Makefile**:
  ```makefile
  job-hourly: ## Run Job 3 (hourly traffic distribution)
      bash scripts/run_job.sh hourly_traffic
      sort -k1 -n data/output/hourly_traffic.raw.txt > data/output/hourly_traffic.txt
  ```
  - Actualizar `results` para imprimir `hourly_traffic.txt`.
  - Actualizar `demo` para incluir `job-hourly`.

  **tests/test_mappers.py** — añadir:
  - `test_hourly_traffic_mapper_extracts_hour_correctly`
  - `test_hourly_traffic_mapper_skips_malformed`
  - `test_hourly_traffic_combiner_sums_same_hour`

- **Comando de verificación**:
  ```bash
  make test
  make job-hourly
  wc -l data/output/hourly_traffic.txt   # 24
  ```
- **Criterio de done**:
  - [ ] `make test` exits 0.
  - [ ] `data/output/hourly_traffic.txt` tiene exactamente 24 líneas (00–23).
  - [ ] Suma de counts ≈ total de requests del dataset.
  - [ ] `make demo` encadena los 3 jobs y exits 0.
  - [ ] Commit: `milestone 11: job 3 hourly_traffic`.

---

### Milestone 12 — EC2: lanzar instancia y desplegar el proyecto

- **Objetivo**: el proyecto corre íntegro en una EC2 en AWS; `make demo` ejecuta los
  3 jobs desde la nube.
- **Archivos a crear**:
  - `scripts/ec2_bootstrap.sh` — script de User Data para la EC2
  - `scripts/ec2_deploy.sh` — sube el proyecto a la EC2 y corre la demo
  - `Makefile` (añadir targets `ec2-up`, `ec2-deploy`, `ec2-demo`, `ec2-down`)
- **Pre-requisitos**: M11, credenciales AWS configuradas.
- **Especificación detallada**:

  **Instancia**:
  - AMI: Amazon Linux 2023 (última disponible en us-east-1).
  - Tipo: `m5.xlarge` (4 vCPU, 16 GB RAM — suficiente para 7 contenedores Hadoop).
  - Storage: 30 GB gp3 (imagen Docker ~2 GB + dataset 205 MB + margen).
  - Security Group: puertos 22, 9870, 8088, 19888 abiertos a `0.0.0.0/0`.

  **scripts/ec2_bootstrap.sh** (User Data — corre al arrancar la instancia):
  ```bash
  #!/bin/bash
  yum update -y
  yum install -y docker git
  systemctl start docker
  systemctl enable docker
  usermod -aG docker ec2-user
  # Docker Compose v2
  mkdir -p /usr/local/lib/docker/cli-plugins
  curl -fsSL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
    -o /usr/local/lib/docker/cli-plugins/docker-compose
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  ```

  **Makefile targets**:
  - `ec2-up`: lanza la instancia con `aws ec2 run-instances`, guarda el Instance ID en
    `.ec2_instance_id`, espera a que esté running, imprime la IP pública.
  - `ec2-deploy`: copia el proyecto a la EC2 con `rsync` o `scp`, excluye
    `data/NASA_*`, `data/output/`, `.git/`.
  - `ec2-demo`: hace SSH a la EC2 y corre `make demo` en remoto; redirige stdout/stderr
    al terminal local para ver el progreso en tiempo real.
  - `ec2-down`: termina la instancia con `aws ec2 terminate-instances`.

  **scripts/ec2_deploy.sh**:
  - Lee IP de `.ec2_ip` (escrita por `ec2-up`).
  - `rsync -avz --exclude` para subir solo el código.
  - En la EC2: `make download && make load` antes de correr jobs
    (el dataset se descarga directo en la EC2, no se sube desde local).

  **Key pair**:
  - `ec2-up` crea un key pair `nasa-demo` si no existe, guarda `nasa-demo.pem` en el
    directorio del proyecto (añadir a `.gitignore`).

- **Comando de verificación**:
  ```bash
  make ec2-up       # imprime IP pública
  make ec2-deploy   # sube el proyecto
  make ec2-demo     # corre make demo en la EC2 (tarda ~15-20 min)
  ```
  Abrir en navegador: `http://<EC2_IP>:8088` (YARN UI) durante la ejecución.

- **Criterio de done**:
  - [ ] `make ec2-up` retorna en < 2 min con la IP pública.
  - [ ] `make ec2-deploy` copia el proyecto sin errores.
  - [ ] `make ec2-demo` exits 0; los 3 jobs corren en la nube.
  - [ ] YARN UI en `:8088` accesible desde el navegador durante la corrida.
  - [ ] NameNode UI en `:9870` muestra 2 live datanodes.
  - [ ] `make ec2-down` termina la instancia.
  - [ ] `.pem` y `.ec2_*` en `.gitignore`.
  - [ ] Commit: `milestone 12: EC2 deploy`.

---

### Milestone 13 — Dashboard: visualización del clúster y resultados

- **Objetivo**: página web accesible en `http://<EC2_IP>` que muestra en tiempo real el
  estado de los jobs, info del clúster, resultados visualizados y logs de ejecución.
- **Archivos a crear**:
  - `dashboard/index.html` — dashboard completo en un solo archivo
  - `scripts/results_to_json.sh` — convierte outputs `.txt` a `.json` para el dashboard
  - `Makefile` (añadir target `ec2-dashboard`)
- **Pre-requisitos**: M12 (EC2 corriendo con Apache).
- **Diseño**: sistema de diseño UP — Geist + Geist Mono, paleta `#FAFAF7` / `#18181B` /
  `#B8924A` / `#1F2A44`. Ver especificación completa en la conversación de diseño.
- **Especificación detallada**:

  **hadoop.env** — añadir para habilitar CORS (permite que el browser haga fetch a YARN/HDFS):
  ```
  YARN-SITE.XML_yarn.timeline-service.http-cross-origin.enabled=true
  CORE-SITE.XML_hadoop.http.cross-origin.enabled=true
  CORE-SITE.XML_hadoop.http.cross-origin.allowed-origins=*
  CORE-SITE.XML_hadoop.http.cross-origin.allowed-methods=GET,POST,HEAD
  CORE-SITE.XML_hadoop.http.cross-origin.allowed-headers=X-Requested-With,Content-Type,Accept,Origin
  ```

  **Secciones del dashboard**:
  1. **Header** — logo `UP · AWS Lab`, IP de la instancia, estado general (dot verde/rojo).
  2. **Cluster info** — tarjetas: Live Datanodes, Replication Factor, Bloques totales,
     Memoria YARN disponible. Datos de `http://EC2_IP:9870/jmx?qry=Hadoop:service=NameNode,name=FSNamesystemState`.
  3. **Jobs** — tabla con los 3 jobs (top_resources, status_bytes, hourly_traffic):
     estado (RUNNING / SUCCEEDED / PENDING), duración, map progress %, reduce progress %.
     Datos de `http://EC2_IP:8088/ws/v1/cluster/apps`. Polling cada 3s mientras hay jobs activos.
  4. **Resultados** — tabs con los 3 outputs:
     - Top 20 URLs (tabla con barra de progreso proporcional al count).
     - Status HTTP (tabla: status, requests, bytes).
     - Hourly traffic (barras horizontales, 24 horas).
     Datos de `/api/results/*.json` generados por `results_to_json.sh`.
  5. **Logs** — terminal oscuro (`#14161C`) con el output de `make demo` en tiempo real.
     Datos de `/api/logs/current.txt`, polling cada 2s. Auto-scroll al fondo.

  **scripts/results_to_json.sh**:
  - Lee `data/output/top_resources.txt`, `status_bytes.txt`, `hourly_traffic.txt`.
  - Escribe `dashboard/api/results/top_resources.json`, etc.
  - Corre automáticamente al terminar cada job (llamado desde `run_job.sh`).

  **Logs en vivo**:
  - `make ec2-demo` redirige stdout a `/var/www/html/api/logs/current.txt` además del terminal.
  - Apache sirve el archivo estático; el dashboard lo hace fetch con `cache: 'no-store'`.

  **Makefile `ec2-dashboard`**:
  - Copia `dashboard/` a `/var/www/html/` en la EC2 via `scp`.
  - Copia `scripts/results_to_json.sh` a la EC2.
  - Crea `/var/www/html/api/results/` y `/var/www/html/api/logs/`.

- **Comando de verificación**:
  ```bash
  make ec2-dashboard
  # Abrir http://<EC2_IP> en el navegador
  # Correr make ec2-demo y ver el dashboard actualizarse en vivo
  ```
- **Criterio de done**:
  - [ ] Dashboard carga en `http://<EC2_IP>` sin errores en la consola del browser.
  - [ ] Cluster info muestra 2 datanodes y replication factor 2.
  - [ ] Jobs se actualizan solos mientras `make demo` corre.
  - [ ] Resultados aparecen en los tabs al terminar cada job.
  - [ ] Logs muestran el output de la terminal en tiempo real.
  - [ ] Diseño usa Geist + paleta UP.
  - [ ] Commit: `milestone 13: dashboard`.

---

### Milestone 14 — Grabación y evidencia para la presentación

- **Objetivo**: capturar video + screenshots de la demo corriendo en AWS para la
  presentación final.
- **Pre-requisitos**: M13.
- **No requiere cambios de código.** Es un milestone de ejecución y documentación.
- **Checklist**:
  - [ ] Grabar terminal con `make ec2-demo` corriendo (usar `asciinema` o grabación de
        pantalla).
  - [ ] Screenshot de YARN ResourceManager UI (`:8088`) mostrando los jobs completados.
  - [ ] Screenshot de NameNode UI (`:9870`) mostrando 2 live datanodes y bloques replicados.
  - [ ] Screenshot de History Server (`:19888`) mostrando los 3 jobs con sus counters.
  - [ ] Crear `docs/ec2_run.md` con: Instance ID, tipo, región, timestamps de inicio/fin,
        costo real de la corrida.
  - [ ] Correr `make ec2-down` al terminar (no dejar la instancia corriendo).
  - [ ] Commit: `milestone 13: demo evidence`.

---

## Convenciones para sesiones Sonnet

Idénticas a `docs/PLAN.md` sección 5, más:

- **Antes de M12–M13**: verificar que `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` y
  `AWS_DEFAULT_REGION` están en el entorno. Si no → STOP.
- **Nunca commitear**: `nasa-demo.pem`, `.ec2_instance_id`, `.ec2_ip`, access keys.
- **Al terminar M12 o M13**: siempre correr `make ec2-down`. Una instancia m5.xlarge
  olvidada encendida cuesta $0.192/hr — en 10 días consume el budget entero.
- **No lanzar más de una instancia EC2 por sesión** sin confirmación del usuario.

## Orden de ejecución

| Sesión | Milestone | Costo AWS |
|---|---|---|
| S8 | M10 — Docker escalado local | $0 |
| S9 | M11 — Job 3 hourly_traffic | $0 |
| S10 | M12 — EC2 deploy | ~$0.40 |
| S11 | M13 — Dashboard | $0 |
| S12 | M14 — Grabación | ~$0.40 |

**Total estimado: < $1.** Con $50 de budget hay margen para más de 50 intentos.
