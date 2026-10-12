# 🚀 Laboratorio: Deploy Canary a Google Cloud Run con GitHub Actions

> **Módulo 5 — DevOps y Automatización del SDLC**  
> **UTEC Posgrado | Arquitectura de Soluciones Multinube**  
> **Docente:** Aldo Trucios

---

## 📋 Descripción

En este laboratorio implementarás un pipeline de **despliegue Canary** sobre **Google Cloud Run** usando **GitHub Actions**. El pipeline automatiza el ciclo completo:

1. **Build** → construye la imagen Docker y la sube a Artifact Registry
2. **Canary (10%)** → despliega la nueva versión con solo el 10% del tráfico
3. **Aprobación manual** → un revisor decide si promover al 100% o hacer rollback
4. **Promote / Rollback** → según la decisión, el tráfico se ajusta automáticamente

```
push a main
     │
     ▼
┌─────────────────────┐
│  build_and_canary   │  ← Build imagen + deploy canary 10%
└────────┬────────────┘
         │ (si NO es primer deploy)
         ▼
┌─────────────────────┐
│ promote_or_rollback │  ← ⏸ Aprobación manual en GitHub
└────────┬────────────┘
         │
    ┌────┴────┐
    │         │
  ✅ OK     ❌ Rechazado / Fallo
    │         │
    ▼         ▼
 100%      rollback_canary
tráfico    (vuelve a versión estable)
```

---

## 🛠️ Pre-requisitos

### 1. Herramientas locales

| Herramienta | Versión mínima | Verificar con |
|-------------|---------------|---------------|
| [Git](https://git-scm.com/) | 2.x | `git --version` |
| [Docker Desktop](https://www.docker.com/products/docker-desktop/) | 24.x | `docker --version` |
| [Google Cloud CLI (`gcloud`)](https://cloud.google.com/sdk/docs/install) | 400+ | `gcloud --version` |
| [Node.js](https://nodejs.org/) | 18 LTS | `node --version` |

> 💡 Puedes usar [GitHub Codespaces](https://github.com/features/codespaces) o Cloud Shell si no quieres instalar todas las herramientas en tu equipo.

### 2. Modelo de trabajo para esta clase: un proyecto GCP compartido

Todos los alumnos utilizan el mismo proyecto de Google Cloud: `utec-posgrado-01`. **No crees un proyecto nuevo ni vuelvas a habilitar las APIs por cada alumno.** El instructor/administrador configura una sola vez las APIs, el pool WIF, el proveedor OIDC y los recursos compartidos de Artifact Registry.

Para evitar colisiones accidentales:

- Cada alumno trabaja en su propio fork/repositorio de GitHub y tiene un `ALUMNO_ID` único (por ejemplo, `jperez`).
- Todos pueden publicar en el repositorio compartido de Artifact Registry `app-gemini`, pero el workflow construye imágenes con nombres diferentes: `app-jperez`, `app-mgarcia`, etc.
- Cada alumno despliega un servicio Cloud Run distinto, por ejemplo `gemini-angular-jperez-dev`.
- El instructor configura WIF para autorizar los repositorios de los alumnos y decide si cada uno tendrá una Service Account dedicada.

**Importante sobre seguridad:** los nombres únicos evitan colisiones, pero no aíslan permisos. Si todas las cuentas de despliegue tienen `roles/run.admin` a nivel de proyecto, podrían modificar o eliminar los servicios de otros alumnos. Para un laboratorio compartido, el administrador debe aceptar explícitamente ese nivel de confianza o diseñar permisos IAM más restrictivos. No compartas un único repositorio GitHub con secrets de alumno distintos: los secrets de repositorio son comunes para todos los workflows de ese repositorio, y los pushes a `main` pueden lanzar despliegues concurrentes.

### 3. Antes de empezar

Necesitas:
- Una cuenta de GitHub y un repositorio donde tengas permisos para administrar Actions y Environments.
- Acceso autorizado al proyecto compartido `utec-posgrado-01`.
- Un repositorio GitHub propio (fork) para tu trabajo.
- Una identidad WIF autorizada para **tu repositorio concreto**, configurada por el instructor/administrador.
- Un `ALUMNO_ID` único asignado o validado por el instructor.

### 4. APIs de GCP (solo instructor/administrador, una vez)

El instructor habilita las APIs en el proyecto compartido. Los alumnos no deben ejecutar este paso salvo indicación expresa del administrador.

```bash
gcloud config set project "utec-posgrado-01"

gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  --project="utec-posgrado-01"
```

---

## ⚙️ Configuración inicial de GCP y WIF (cada alumno)

En este laboratorio **cada alumno configura su propia federación WIF**, igual que en la demostración del docente. Todos trabajan dentro del mismo proyecto de GCP, `utec-posgrado-01`, pero cada alumno debe usar nombres únicos para su pool, proveedor OIDC, Service Account, imagen y servicio Cloud Run.

> **Antes de ejecutar comandos:** para completar tú mismo todos los pasos, tu identidad de usuario debe tener permisos para crear pools/proveedores WIF, Service Accounts y repositorios Artifact Registry, y modificar las políticas IAM requeridas. Esto concede privilegios amplios dentro del proyecto compartido. El instructor debe aprobar y habilitar expresamente esos permisos; si no, tendrá que ejecutar los pasos de IAM por ti. Si recibes `PERMISSION_DENIED`, detente y solicita al administrador que otorgue los permisos o ejecute el paso correspondiente. No generes claves JSON ni solicites `roles/owner`.

### 1. Preparar variables

Ejecuta en Cloud Shell o en una terminal con Google Cloud CLI autenticado:

```bash
gcloud auth login
gcloud config set project utec-posgrado-01

export PROJECT_ID="utec-posgrado-01"
export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"

# Usa solo letras minúsculas y números; identifica tu cuenta/alumno y que sea único.
export ALUMNO_ID="jperez" # CAMBIAR por tu identificador único

export POOL_ID="github-pool-$ALUMNO_ID"
export PROVIDER_ID="github-provider-$ALUMNO_ID"
export SA_ID="github-actions-$ALUMNO_ID"
export SA_EMAIL="$SA_ID@$PROJECT_ID.iam.gserviceaccount.com"
export RUNTIME_SA_ID="cloud-run-$ALUMNO_ID"
export RUNTIME_SA_EMAIL="$RUNTIME_SA_ID@$PROJECT_ID.iam.gserviceaccount.com"
export REPOSITORY="TU_USUARIO_GITHUB/angular-cloud-run-v2" # CAMBIAR por OWNER/REPO de tu fork
export GITHUB_ENVIRONMENT="dev"
export GCP_REGION="us-central1"
export ARTIFACT_REGISTRY_REPO="app-$ALUMNO_ID"
```

**Importante:** reemplaza `ALUMNO_ID` y `REPOSITORY` por tus propios valores antes de ejecutar los comandos. No uses el repositorio del docente como si fuera tu fork. El repositorio debe existir en GitHub y coincidir exactamente con `OWNER/REPO`.

### 2. Habilitar APIs

El instructor puede haberlas habilitado ya para el proyecto compartido. Verifica primero; habilítalas solo si tienes permiso y no están habilitadas:

```bash
gcloud services enable \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  --project="$PROJECT_ID"
```

### 3. Crear tu Service Account de despliegue

Cada alumno debe crear dos identidades distintas: una Service Account de despliegue para GitHub Actions y otra identidad de ejecución para su servicio Cloud Run.

```bash
gcloud iam service-accounts create "$SA_ID" \
  --project="$PROJECT_ID" \
  --display-name="GitHub Actions $ALUMNO_ID"
```

Si la cuenta ya existe, no intentes crearla de nuevo; verifica que sea la tuya:

```bash
gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID"
```

### 4. Crear tu pool de Workload Identity Federation

```bash
gcloud iam workload-identity-pools create "$POOL_ID" \
  --project="$PROJECT_ID" \
  --location="global" \
  --display-name="GitHub Pool $ALUMNO_ID"
```

Si el pool ya existe, consúltalo y continúa con ese recurso propio; no crees otro con el mismo nombre.

### 5. Crear tu proveedor OIDC de GitHub

El proveedor solo debe confiar en tu repositorio y en el Environment `dev`:

```bash
gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
  --project="$PROJECT_ID" \
  --location="global" \
  --workload-identity-pool="$POOL_ID" \
  --display-name="GitHub OIDC $ALUMNO_ID" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.environment=assertion.environment" \
  --attribute-condition="assertion.repository == '$REPOSITORY' && assertion.environment == '$GITHUB_ENVIRONMENT'"
```

La condición limita la confianza al repositorio que declaraste y al Environment `dev`. No la cambies por una condición abierta que acepte cualquier repositorio.

### 6. Permitir que tu repositorio use tu Service Account

```bash
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$POOL_ID/attribute.repository/$REPOSITORY"
```

### 7. Conceder permisos de despliegue

El workflow necesita permiso para desplegar Cloud Run, publicar imágenes en Artifact Registry y usar la cuenta de ejecución de Cloud Run. Los siguientes comandos asignan roles a tu Service Account:

```bash
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/run.admin"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/artifactregistry.writer"

gcloud iam service-accounts create "$RUNTIME_SA_ID" \
  --project="$PROJECT_ID" \
  --display-name="Cloud Run runtime $ALUMNO_ID"

gcloud iam service-accounts add-iam-policy-binding "$RUNTIME_SA_EMAIL" \
  --project="$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/iam.serviceAccountUser"
```

> **Advertencia de seguridad para el proyecto compartido:** `roles/run.admin` asignado a nivel de proyecto permite administrar servicios de Cloud Run de otros alumnos, no solo el propio. `roles/artifactregistry.writer` a nivel de proyecto también puede dar acceso de escritura más amplio de lo necesario. Usa estos comandos únicamente si el instructor aprobó este modelo de confianza. Para aislamiento real, el administrador debe definir permisos más restringidos por recurso/rol personalizado; nombres diferentes por sí solos no son una barrera de seguridad. Si tu usuario no puede asignar estos roles, pide al instructor que los conceda o ejecute los comandos.

### 8. Crear tu propio repositorio de Artifact Registry

Cada alumno crea su propio repositorio Docker en el proyecto compartido. Así no comparten el repositorio de imágenes entre alumnos:

```bash
gcloud artifacts repositories create "$ARTIFACT_REGISTRY_REPO" \
  --project="$PROJECT_ID" \
  --location="$GCP_REGION" \
  --repository-format=docker \
  --description="Imágenes de Cloud Run para $ALUMNO_ID"
```

Si ya existe un repositorio con ese nombre, comprueba que sea el tuyo antes de continuar. No borres ni reutilices el repositorio de otro alumno.

Concede a tu Service Account acceso de escritura únicamente a tu repositorio:

```bash
gcloud artifacts repositories add-iam-policy-binding "$ARTIFACT_REGISTRY_REPO" \
  --project="$PROJECT_ID" \
  --location="$GCP_REGION" \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/artifactregistry.writer"
```

El repositorio de imágenes será `app-$ALUMNO_ID` y la imagen tendrá una ruta como `us-central1-docker.pkg.dev/utec-posgrado-01/app-jperez/app-jperez:<commit>`.

### 9. Obtener los valores para GitHub Actions

Obtén el nombre completo del proveedor WIF:

```bash
gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
  --project="$PROJECT_ID" \
  --location="global" \
  --workload-identity-pool="$POOL_ID" \
  --format="value(name)"
```

Copia el resultado completo; tendrá esta forma:

```text
projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/github-pool-ALUMNO_ID/providers/github-provider-ALUMNO_ID
```

Usa el valor real devuelto por el comando, no el texto de ejemplo. En tu fork, abre **Settings → Secrets and variables → Actions** y configura las variables y secrets de la siguiente sección.

### Recursos comunes y recursos independientes

**Comunes para la clase:** el proyecto GCP `utec-posgrado-01`, las APIs habilitadas y la región `us-central1`.

**Independientes por alumno:** fork de GitHub, pool WIF, proveedor OIDC, Service Account de despliegue, Service Account de ejecución de Cloud Run, repositorio Artifact Registry, nombre de imagen y servicio Cloud Run.

El proyecto GCP sigue siendo compartido, por lo que los permisos IAM del proyecto no quedan aislados automáticamente.
---

## 🔐 Configuración de GitHub Actions

En tu propio repositorio, abre **Settings → Secrets and variables → Actions**.

### Variables del repositorio

| Nombre | Valor |
| --- | --- |
| `GCP_WIF_PROVIDER` | Nombre completo que obtuviste en el paso 8 (tu proveedor WIF) |
| `GCP_SERVICE_ACCOUNT` | Email de tu Service Account: `github-actions-ALUMNO_ID@utec-posgrado-01.iam.gserviceaccount.com` |
| `ARTIFACT_REGISTRY_REPO` | Nombre de tu repositorio Artifact Registry: `app-ALUMNO_ID` |
| `CLOUD_RUN_RUNTIME_SERVICE_ACCOUNT` | Email de tu identidad de ejecución: `cloud-run-ALUMNO_ID@utec-posgrado-01.iam.gserviceaccount.com` |

### Secrets del repositorio

| Nombre | Valor |
| --- | --- |
| `ALUMNO_ID` | Alias único, por ejemplo `jperez` |
| `ENVIRONMENT_NAME` | `dev` (o el Environment acordado con el instructor) |

No configures `GCP_SA_KEY` ni guardes claves JSON. Configura estas variables en tu **fork personal**. No pongas valores diferentes de `ALUMNO_ID` en el mismo repositorio esperando que cada alumno tenga un secreto propio: los repository secrets son compartidos por todos los workflows de ese repositorio.

### Environment y aprobación manual

En **Settings → Environments**, crea el Environment que corresponda al valor de `ENVIRONMENT_NAME`. Si el laboratorio debe pausar para aprobación, configura **Required reviewers**. El nombre debe coincidir exactamente con el que espera la condición OIDC configurada en GCP.

---

## ⚠️ Revisar workflows antes del primer push

En el repositorio original existe también `.github/workflows/workflow-reuse.yml`, que se ejecuta al hacer push a `main` y despliega a otro proyecto de GCP. Para este laboratorio compartido, **no ejecutes dos pipelines por accidente**: en tu fork, deshabilita ese workflow desde **Actions** o elimínalo de tu fork si no forma parte del ejercicio. Conserva habilitado `.github/workflows/utec.yml`, que apunta a `utec-posgrado-01`.

Cada alumno debe hacer push a la rama `main` de su propio fork. No hagan push todos al repositorio del docente: los secrets/variables del repositorio se comparten entre sus workflows y los pushes pueden disparar despliegues concurrentes.

---

## 🧪 Prueba completa como alumno nuevo

Haz esta prueba desde un fork nuevo o desde un repositorio de prueba que no tenga configuración previa. Usa un alias temporal único, por ejemplo `jperezlab`, para no tocar recursos de otro alumno.

- [ ] El fork existe y el workflow `.github/workflows/utec.yml` está en la rama `main`.
- [ ] En GCP creaste tu Service Account, pool WIF, proveedor OIDC y repositorio Artifact Registry con nombres propios.
- [ ] La condición OIDC contiene el nombre exacto de tu fork y el Environment `dev`.
- [ ] En GitHub configuraste las variables `GCP_WIF_PROVIDER`, `GCP_SERVICE_ACCOUNT` y `ARTIFACT_REGISTRY_REPO`.
- [ ] En GitHub configuraste los secrets `ALUMNO_ID` y `ENVIRONMENT_NAME=dev`.
- [ ] Creaste el Environment `dev` en **Settings → Environments**.
- [ ] Deshabilitaste o quitaste `.github/workflows/workflow-reuse.yml` en el fork para evitar un segundo despliegue a otro proyecto.
- [ ] Hiciste un cambio pequeño y ejecutaste `git push origin main`.
- [ ] En Actions, el primer job pasó autenticación WIF, build, push de imagen y creación del servicio Cloud Run.
- [ ] Verificaste que la URL del servicio sea la de tu propio servicio y que otro alumno no comparta su nombre.

Si el paso de autenticación falla, revisa primero el proveedor y el principal federado. Si la autenticación funciona pero falla al crear Cloud Run, revisa el permiso `roles/run.admin`. Si falla al subir la imagen, revisa el permiso de escritura en **tu repositorio Artifact Registry**. No cambies los nombres ni amplíes los permisos a ciegas.

**Límite importante:** como el proyecto GCP es compartido, el paso de asignar `roles/run.admin` a nivel de proyecto permite a esa Service Account administrar servicios de otros alumnos. Cada alumno tendrá recursos y credenciales WIF separados, pero no aislamiento completo de permisos. Para una práctica donde todos ejecutan el setup por sí mismos, el administrador debe aceptar este modelo o diseñar roles IAM más restrictivos.

---

## 🚀 Ejecución del Pipeline

### Primera ejecución (primer deploy)

En el **primer push**, el pipeline detecta que el servicio de Cloud Run no existe todavía y despliega con el **100% del tráfico** directamente (no hay Canary en el primer deploy, no habría versión estable a la que volver).

```bash
git add .
git commit -m "feat: primer despliegue a Cloud Run"
git push origin main
```

Observa en GitHub → **Actions** cómo:
1. Se ejecuta el job `build_and_canary`
2. El step "Check if Service Exists" detecta que es primer deploy (`is_first_deploy=true`)
3. El job `promote_or_rollback` **se salta** (condición `if: ... == 'false'`)

---

### Ejecuciones siguientes (Canary deploy)

A partir del **segundo push**, el pipeline activa el flujo Canary completo:

```bash
# Haz algún cambio en la aplicación, por ejemplo en src/app/app.component.html
git add .
git commit -m "feat: nueva versión con cambio visible"
git push origin main
```

El pipeline:

1. ✅ **`build_and_canary`** — construye la imagen y asigna **90% tráfico a la versión estable / 10% a la nueva (Canary)**
2. ⏸ **`promote_or_rollback`** — **se pausa** esperando tu aprobación en GitHub
3. Ve a **Actions** → haz clic en el run activo → verás el botón **"Review deployments"**
4. Selecciona el environment `dev` y elige:
   - ✅ **Approve** → el Canary sube al **100% del tráfico**
   - ❌ **Reject** → se dispara `rollback_canary` y la versión estable vuelve al **100%**

---

## 🔍 Verificar el Despliegue

### Desde la terminal

```bash
# Define estos valores para tu propio proyecto y tu alias.
PROJECT_ID="utec-posgrado-01"
ALUMNO_ID="TU_ALUMNO_ID"
ENVIRONMENT_NAME="dev"
GCP_REGION="us-central1"
SERVICE_NAME="gemini-angular-$ALUMNO_ID-$ENVIRONMENT_NAME"

gcloud run services describe "$SERVICE_NAME" \
  --project="$PROJECT_ID" \
  --region="$GCP_REGION" \
  --format="table(status.url,status.traffic)"

# Ver la distribución de tráfico entre revisiones
gcloud run services describe "$SERVICE_NAME" \
  --project="$PROJECT_ID" \
  --region="$GCP_REGION" \
  --format="value(status.traffic)"
```

### Desde la consola de GCP

1. Ve a [console.cloud.google.com](https://console.cloud.google.com)
2. Navega a **Cloud Run**
3. Haz clic en tu servicio `gemini-angular-TU_ALUMNO_ID-dev`
4. En la pestaña **"Traffic"** verás las revisiones y sus porcentajes

---

## 📁 Estructura del Repositorio

```
angular-cloud-run-v2/
├── .github/
│   └── workflows/
│       ├── utec.yml              ← Pipeline principal (este laboratorio)
│       └── workflow-reuse.yml    ← Workflow reutilizable (referencia)
├── src/
│   └── app/
│       ├── app.component.html
│       ├── app.component.scss
│       ├── app.component.ts
│       ├── app.config.ts
│       └── app.routes.ts
├── Dockerfile                    ← Imagen Docker de la app Angular
├── nginx.conf                    ← Configuración del servidor web
├── entrypoint.sh
├── angular.json
├── package.json
└── README.md                     ← Este archivo
```

---

## 🧠 Conceptos del Workflow Explicados

### Outputs entre jobs

```yaml
outputs:
  is_first_deploy: ${{ steps.check_service.outputs.is_first_deploy }}
```

El job `build_and_canary` expone un output que los jobs siguientes consumen con `needs.build_and_canary.outputs.is_first_deploy`. Así el pipeline toma decisiones basadas en el estado real de la infraestructura.

### Ejecución condicional con `if:`

```yaml
# Solo corre si NO es el primer deploy
if: needs.build_and_canary.outputs.is_first_deploy == 'false'

# Solo corre si hubo fallo o cancelación en el job anterior
if: always() && ... && (needs.promote_or_rollback.result == 'failure' || needs.promote_or_rollback.result == 'cancelled')
```

### Gate de aprobación manual (Environment)

```yaml
environment: dev
```

Cuando un job referencia un Environment configurado con **Required reviewers**, GitHub pausa la ejecución y muestra un botón de aprobación. Si el revisor rechaza, el job queda en estado `cancelled`, lo que activa el job de rollback.

### Secretos de alumno para multi-usuario

```yaml
SERVICE_NAME="gemini-angular-${{ secrets.ALUMNO_ID }}-${{ secrets.ENVIRONMENT_NAME }}"
IMAGE_TAG="..../app-${{ secrets.ALUMNO_ID }}:${{ github.sha }}"
```

Cada alumno usa su propio `ALUMNO_ID` para generar nombres distintos de servicio e imagen. Esto evita ciertas colisiones de nombres, pero no configura los permisos ni garantiza aislamiento de seguridad. Para aislar recursos, usa un proyecto propio o permisos IAM delimitados.

---

## ❗ Troubleshooting

### Error: `Permission denied` al hacer push a Artifact Registry

```bash
# Reautenticar Docker con GCP
gcloud auth configure-docker us-central1-docker.pkg.dev
```

### Error: `The caller does not have permission`

Verifica que la Service Account tiene los roles correctos:

```bash
gcloud projects get-iam-policy "$PROJECT_ID" \
  --flatten="bindings[].members" \
  --filter="bindings.members:$GCP_SERVICE_ACCOUNT"
```

### Error de Workload Identity Federation

Verifica que `GCP_WIF_PROVIDER` contenga el nombre completo del proveedor, que `GCP_SERVICE_ACCOUNT` sea el correo exacto de la SA y que los tres jobs tengan `id-token: write`. Comprueba además que el proveedor permita únicamente tu repositorio y el Environment `dev`, y que tu SA tenga `roles/iam.workloadIdentityUser` para el principal de tu pool.

### El job `promote_or_rollback` nunca aparece

Verifica que el output `is_first_deploy` sea `false`. Esto solo ocurre a partir del **segundo push**. En el primer deploy, ese job se omite por diseño.

### El servicio de Cloud Run no es accesible

```bash
# Verifica que el flag --allow-unauthenticated está activo
gcloud run services describe gemini-angular-TU_ALUMNO_ID-dev \
  --region us-central1 \
  --format="value(spec.template.spec.containers[0].image)"
```

---

## 🧹 Limpieza de Recursos (al finalizar el laboratorio)

Para evitar cargos en GCP, elimina los recursos creados:

```bash
# Eliminar el servicio de Cloud Run
gcloud run services delete "gemini-angular-TU_ALUMNO_ID-dev" \
  --region us-central1 --quiet

# Eliminar las imágenes SOLO si este repositorio pertenece a tu alumno/proyecto.
# Sustituye ARTIFACT_REGISTRY_REPO por el nombre de tu repositorio.
gcloud artifacts docker images delete \
  "us-central1-docker.pkg.dev/utec-posgrado-01/TU_ARTIFACT_REGISTRY_REPO/app-TU_ALUMNO_ID" \
  --delete-tags --quiet

# No elimines la Service Account, el pool WIF ni el provider compartido del instructor.
# Elimina una cuenta propia solo si confirmas que no la utiliza ningún otro recurso.
```

---

## 📚 Referencias

- [GitHub Actions — Environments y aprobaciones](https://docs.github.com/en/actions/managing-workflow-runs/reviewing-deployments)
- [GitHub Actions — Outputs entre jobs](https://docs.github.com/en/actions/using-workflows/workflow-syntax-for-github-actions#jobsjob_idoutputs)
- [Google Cloud Run — Traffic splitting](https://cloud.google.com/run/docs/rollouts-rollbacks-traffic-migration)
- [Artifact Registry — Autenticación Docker](https://cloud.google.com/artifact-registry/docs/docker/authentication)
- [Google Cloud — Workload Identity Federation with deployment pipelines](https://cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines)
- [google-github-actions/auth](https://github.com/google-github-actions/auth)

---

*Material elaborado para UTEC Posgrado — Módulo 5, Sesión 1 | Docente: Aldo Trucios*


