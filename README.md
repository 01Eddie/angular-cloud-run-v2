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

> 💡 **Alternativa sin instalación local:** usa [GitHub Codespaces](https://github.com/features/codespaces). Abre el repositorio en GitHub → `Code` → `Codespaces` → `Create codespace on main`. Todas las herramientas ya están preinstaladas.

### 2. Cuentas y accesos

- ✅ Cuenta de **GitHub** (gratuita)
- ✅ Cuenta de **Google Cloud Platform** con proyecto activo
- ✅ Proyecto GCP con **billing habilitado**
- ✅ Proyecto GCP con permisos para desplegar recursos. La configuración inicial de IAM/WIF puede requerir que un administrador ejecute algunos comandos.

### 3. APIs de GCP habilitadas

Ejecuta los siguientes comandos en tu terminal (o en Cloud Shell):

```bash
gcloud config set project utec-posgrado-01

gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  iam.googleapis.com
```

Verifica que estén activas:

```bash
gcloud services list --enabled \
  --filter="name:(run.googleapis.com OR artifactregistry.googleapis.com)"
```

---

## ⚙️ Configuración Inicial (hacer una sola vez)

> **Estado actual del instructor:** proyecto `utec-posgrado-01`; Service Account `github-actions-sa-jtruc@utec-posgrado-01.iam.gserviceaccount.com` ya existe y está habilitada; pool `github-pool` ya fue creado. Continúa con la verificación/configuración, no repitas la creación de esos recursos. Para el paso a paso completo, consulta [`docs/WIF-GCP-SETUP.md`](docs/WIF-GCP-SETUP.md).

### PASO 1 — Crear el repositorio de Artifact Registry

Artifact Registry es donde se almacenarán las imágenes Docker que construya el pipeline.

```bash
gcloud artifacts repositories create app-gemini \
  --repository-format=docker \
  --location=us-central1 \
  --description="Repositorio de imágenes Docker — UTEC Posgrado"
```

Verifica que se creó correctamente:

```bash
gcloud artifacts repositories list --location=us-central1
```

---

### PASO 2 — Verificar y preparar la Service Account existente para GitHub Actions

El workflow se autentica mediante **Workload Identity Federation (WIF)** y OIDC de GitHub. No necesita una clave JSON. En este proyecto ya existe esta cuenta de servicio habilitada; reutilízala y no crees otra:

Cuenta de servicio existente: `github-actions-sa-jtruc@utec-posgrado-01.iam.gserviceaccount.com`.

```bash
export PROJECT_ID="utec-posgrado-01"
export SA_EMAIL="github-actions-sa-jtruc@$PROJECT_ID.iam.gserviceaccount.com"
export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"

gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID"

gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$SA_EMAIL" --role="roles/run.admin"
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$SA_EMAIL" --role="roles/artifactregistry.writer"

# Permitir a la SA de despliegue actuar como la SA de ejecución predeterminada de Cloud Run.
RUNTIME_SA="$PROJECT_NUMBER-compute@developer.gserviceaccount.com"
gcloud iam service-accounts add-iam-policy-binding "$RUNTIME_SA" --project="$PROJECT_ID" --member="serviceAccount:$SA_EMAIL" --role="roles/iam.serviceAccountUser"
```

La cuenta ya existe y se reutiliza. Si Cloud Run utiliza una SA de ejecución personalizada, concede `roles/iam.serviceAccountUser` sobre esa SA concreta.

### PASO 3 — Configurar Workload Identity Federation en GCP

Ejecuta estos comandos con una identidad que tenga permisos para administrar APIs, Workload Identity Pools y políticas IAM. El proveedor restringe la confianza al repositorio `aldower/angular-cloud-run-v2` y al Environment `dev`.

```bash
export PROJECT_ID="utec-posgrado-01"
export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
export POOL_ID="github-pool"
export PROVIDER_ID="github-provider"
export SA_EMAIL="github-actions-sa-jtruc@$PROJECT_ID.iam.gserviceaccount.com"

gcloud services enable iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com --project="$PROJECT_ID"

# El pool github-pool ya fue creado. Solo créalo si la consulta anterior confirma que no existe.
gcloud iam workload-identity-pools describe "$POOL_ID" --project="$PROJECT_ID" --location="global"

# Ejecuta create-oidc solo si github-provider todavía no existe.
gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" --project="$PROJECT_ID" --location="global" --workload-identity-pool="$POOL_ID" --display-name="GitHub Actions OIDC provider" --issuer-uri="https://token.actions.githubusercontent.com" --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.environment=assertion.environment" --attribute-condition="assertion.repository == 'aldower/angular-cloud-run-v2' && assertion.environment == 'dev'"

gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" --project="$PROJECT_ID" --role="roles/iam.workloadIdentityUser" --member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$POOL_ID/attribute.repository/aldower/angular-cloud-run-v2"

gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" --project="$PROJECT_ID" --location="global" --workload-identity-pool="$POOL_ID" --format="value(name)"
```

Copia el nombre completo que devuelve el último comando (formato `projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/github-pool/providers/github-provider`). No uses `roles/owner` para la Service Account: asigna únicamente los roles que requiere el despliegue.

### PASO 4 — Crear el Environment `dev` en GitHub

El job `promote_or_rollback` usa un **Environment** de GitHub para requerir aprobación manual. Debes crearlo antes de ejecutar el pipeline.

1. Ve a tu repositorio en GitHub
2. Haz clic en **Settings** → **Environments**
3. Haz clic en **"New environment"**
4. Nombre: `dev`
5. Haz clic en **"Configure environment"**
6. En **"Required reviewers"**: agrega tu propio usuario (o el del equipo)
7. Haz clic en **"Save protection rules"**

> 🔐 Esto hace que el job `promote_or_rollback` pause y espere tu aprobación en GitHub antes de ejecutarse.

---

### PASO 5 — Configurar Secrets y Variables en GitHub

Ve a tu repositorio → **Settings → Secrets and variables → Actions**.

#### 🔒 Secrets (pestaña "Secrets")

Crea estos **Repository secrets**:

| Secret Name | Valor | Descripción |
|-------------|-------|-------------|
| `ALUMNO_ID` | `tu-nombre-o-alias` | Identificador único sin espacios, en minúsculas (ej. `jperez`) |
| `ENVIRONMENT_NAME` | `dev` | Sufijo del entorno de despliegue |

**No crees `GCP_SA_KEY`**: el workflow ya no consume claves JSON.

#### 📦 Variables (pestaña "Variables")

Crea estas **Repository variables**:

| Variable Name | Valor | Descripción |
|---------------|-------|-------------|
| `GCP_WIF_PROVIDER` | Nombre completo del provider que devuelve el último comando del paso 3 | Identificador del proveedor WIF |
| `GCP_SERVICE_ACCOUNT` | `github-actions-sa-jtruc@utec-posgrado-01.iam.gserviceaccount.com` | Correo de la Service Account de despliegue |

Usa exactamente el correo existente `github-actions-sa-jtruc@utec-posgrado-01.iam.gserviceaccount.com`. Configura las variables a nivel de repositorio para que estén disponibles en los jobs que usan el Environment `dev`.

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
# Ver el servicio desplegado
SERVICE_NAME="gemini-angular-TU_ALUMNO_ID-dev"

gcloud run services describe $SERVICE_NAME \
  --region us-central1 \
  --format="table(status.url,status.traffic)"

# Ver la distribución de tráfico entre revisiones
gcloud run services describe $SERVICE_NAME \
  --region us-central1 \
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

Cada alumno usa su propio `ALUMNO_ID` como secreto, lo que genera nombres de servicio e imágenes únicos. Así todos trabajan en el mismo proyecto GCP sin colisiones.

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
gcloud projects get-iam-policy utec-posgrado-01 \
  --flatten="bindings[].members" \
  --filter="bindings.members:github-actions-sa"
```

### Error de Workload Identity Federation

Verifica que `GCP_WIF_PROVIDER` contenga el nombre completo del proveedor, que `GCP_SERVICE_ACCOUNT` sea el correo exacto de la SA y que los tres jobs tengan `id-token: write`. Comprueba además que el proveedor permita únicamente el repositorio y el Environment `dev`, y que la SA tenga `roles/iam.workloadIdentityUser` para el principal del pool.

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

# Eliminar las imágenes del Artifact Registry
gcloud artifacts docker images delete \
  "us-central1-docker.pkg.dev/utec-posgrado-01/app-gemini/app-TU_ALUMNO_ID" \
  --delete-tags --quiet

# (Opcional) Eliminar la Service Account
gcloud iam service-accounts delete \
  "github-actions-sa@utec-posgrado-01.iam.gserviceaccount.com" --quiet
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


