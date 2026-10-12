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

### 2. Modelo de trabajo para un aula

**Importante: no ejecutes todos los comandos de IAM/WIF de forma independiente en el proyecto compartido.** El pool WIF, el proveedor OIDC, la cuenta de despliegue y los permisos de proyecto son infraestructura compartida y deben configurarse una sola vez por el instructor o el administrador.

Hay dos modelos válidos:

- **Recomendado para la clase:** cada alumno trabaja en su propio fork/repositorio GitHub y usa su propio proyecto de Google Cloud. Así tiene su identidad, permisos, Artifact Registry, Cloud Run y aprobaciones independientes.
- **Proyecto GCP compartido por la clase:** el instructor configura WIF/IAM una vez. Cada alumno debe tener un repositorio GitHub autorizado individualmente por la federación y una identidad de despliegue aislada, o el instructor debe controlar de forma explícita los permisos. No compartas una única Service Account con permisos amplios entre todos los alumnos si quieres aislamiento real.

Un `ALUMNO_ID` único solo separa nombres de recursos; **no crea aislamiento de seguridad**. Los secrets y variables configurados a nivel de repositorio también son compartidos entre quienes pueden ejecutar workflows en ese repositorio. Si todos editan y hacen push a la misma rama `main`, pueden disparar despliegues concurrentes o sobrescribir la misma configuración.

### 3. Antes de empezar

Necesitas:
- Una cuenta de GitHub y un repositorio donde tengas permisos para administrar Actions y Environments.
- Un proyecto de GCP con billing habilitado.
- Permisos para desplegar en Cloud Run y publicar imágenes en Artifact Registry, otorgados por el administrador.
- Una identidad WIF configurada para **tu repositorio concreto**. No reutilices a ciegas el proveedor configurado para el repositorio del instructor.

### 4. APIs de GCP

Ejecuta esto solamente si tienes un proyecto propio o el instructor te indicó explícitamente que habilites APIs en el proyecto compartido:

```bash
export PROJECT_ID="TU_PROJECT_ID"
gcloud config set project "$PROJECT_ID"

gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com
```

Comprueba las APIs:

```bash
gcloud services list --enabled \
  --filter="name:(run.googleapis.com OR artifactregistry.googleapis.com OR iam.googleapis.com)"
```

---

## ⚙️ Configuración inicial de GCP y WIF

### Qué debe hacer el instructor/administrador (una sola vez por configuración)

El instructor configura los recursos de confianza y los permisos necesarios: proveedor OIDC de GitHub, cuenta(s) de servicio de despliegue y permisos mínimos. **No todos los alumnos deben ejecutar** `gcloud projects add-iam-policy-binding`, `gcloud iam workload-identity-pools providers create-oidc` ni `gcloud iam service-accounts add-iam-policy-binding` sobre la infraestructura compartida.

Para la configuración ya existente del entorno del instructor, consulta [`docs/WIF-GCP-SETUP.md`](docs/WIF-GCP-SETUP.md). Esa guía describe el entorno de instructor; no la ejecutes íntegramente contra el proyecto compartido sin autorización del administrador.

### Qué configura cada alumno

1. Crea un fork o repositorio propio a partir del laboratorio.
2. Identifica su proyecto GCP (`PROJECT_ID`) y su repositorio GitHub (`OWNER/REPO`).
3. Solicita al instructor/administrador una federación WIF autorizada para **ese repositorio**. El proveedor debe validar el repositorio y, si se usa, un Environment concreto. No se debe asumir que el proveedor existente permite repositorios de alumnos.
4. Usa una Service Account de despliegue dedicada al alumno (preferible) o el mecanismo aislado que el administrador haya definido.
5. Crea un repositorio Artifact Registry con nombre único dentro de su proyecto, o utiliza el repositorio que el administrador le haya asignado.
6. No generes ni guardes claves JSON. El workflow debe autenticarse mediante OIDC/WIF.

**Importante: el workflow actual todavía tiene valores fijos** en `.github/workflows/utec.yml` (`GCP_PROJECT_ID`, `GCP_REGION` y `ARTIFACT_REGISTRY_REPO`). En tu fork, edita esos valores para que apunten a tu proyecto y al repositorio de imágenes que te asignaron. Los comandos `export` de esta guía no cambian automáticamente las variables `env:` que están escritas dentro del archivo YAML. No ejecutes el pipeline hasta confirmar que esos valores y las variables WIF correspondan a tu entorno.

### Recursos con nombres únicos

Para evitar colisiones dentro de un proyecto compartido, define un alias único, en minúsculas y sin espacios. Por ejemplo:

```bash
export ALUMNO_ID="jperez"          # reemplázalo por tu alias único
export ENVIRONMENT_NAME="dev"      # debe coincidir con el Environment de GitHub
export GCP_REGION="us-central1"
export ARTIFACT_REGISTRY_REPO="app-gemini-$ALUMNO_ID"
export SERVICE_NAME="gemini-angular-$ALUMNO_ID-$ENVIRONMENT_NAME"
```

Si el repositorio Artifact Registry `app-gemini` ya fue creado por el instructor y se permite compartirlo, **no intentes crearlo otra vez**. Usa el repo asignado o pide al instructor que confirme la convención. La separación por nombre reduce colisiones de recursos, pero no impide que una persona con permisos amplios modifique recursos de otra.

### Artifact Registry (solo cuando el administrador te asignó permiso para crearlo)

```bash
gcloud artifacts repositories create "$ARTIFACT_REGISTRY_REPO" \
  --project="$PROJECT_ID" \
  --repository-format=docker \
  --location="$GCP_REGION" \
  --description="Imágenes del laboratorio para $ALUMNO_ID"
```

Si el repositorio ya existe, confirma que es el que te han asignado:

```bash
gcloud artifacts repositories describe "$ARTIFACT_REGISTRY_REPO" \
  --project="$PROJECT_ID" --location="$GCP_REGION"
```

---

## 🔐 Configuración de GitHub Actions

En tu propio repositorio, abre **Settings → Secrets and variables → Actions**.

### Variables del repositorio

| Nombre | Valor |
| --- | --- |
| `GCP_WIF_PROVIDER` | Nombre completo del proveedor WIF autorizado para tu repositorio |
| `GCP_SERVICE_ACCOUNT` | Email de la Service Account de despliegue autorizada para tu repositorio |

### Secrets del repositorio

| Nombre | Valor |
| --- | --- |
| `ALUMNO_ID` | Alias único, por ejemplo `jperez` |
| `ENVIRONMENT_NAME` | `dev` (o el Environment acordado con el instructor) |

No configures `GCP_SA_KEY` ni guardes claves JSON. Si varios alumnos usan el mismo repositorio, estos secretos son compartidos y no sirven para separar quién ejecuta un workflow; trabaja en tu propio fork/repositorio para mantener tu configuración separada.

### Environment y aprobación manual

En **Settings → Environments**, crea el Environment que corresponda al valor de `ENVIRONMENT_NAME`. Si el laboratorio debe pausar para aprobación, configura **Required reviewers**. El nombre debe coincidir exactamente con el que espera la condición OIDC configurada en GCP.

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
PROJECT_ID="TU_PROJECT_ID"
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

# Eliminar las imágenes SOLO si este repositorio pertenece a tu alumno/proyecto.
# Sustituye PROJECT_ID y ARTIFACT_REGISTRY_REPO por los valores reales.
gcloud artifacts docker images delete \
  "us-central1-docker.pkg.dev/TU_PROJECT_ID/TU_ARTIFACT_REGISTRY_REPO/app-TU_ALUMNO_ID" \
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


