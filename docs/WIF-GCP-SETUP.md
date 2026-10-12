# Configuración paso a paso: GitHub Actions + Workload Identity Federation

Esta guía configura la autenticación de GitHub Actions hacia Google Cloud sin claves JSON para el laboratorio Angular → Artifact Registry → Cloud Run.

## Estado inicial del proyecto del instructor

- Proyecto: `utec-posgrado-01`
- Pool ya creado: `github-pool` (ubicación `global`)
- Cuenta de servicio existente y habilitada: `github-actions-sa-jtruc@utec-posgrado-01.iam.gserviceaccount.com`
- Repositorio GitHub autorizado: `aldower/angular-cloud-run-v2`
- GitHub Environment: `dev`

> No vuelvas a crear el pool ni la cuenta de servicio. Si un comando de IAM devuelve `PERMISSION_DENIED`, detente y pide a un administrador que ejecute ese paso; no intentes resolverlo creando claves JSON ni concediendo `roles/owner`.

## 1. Seleccionar el proyecto y definir variables

Ejecuta en Cloud Shell:

```bash
gcloud config set project utec-posgrado-01

export PROJECT_ID="utec-posgrado-01"
export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
export POOL_ID="github-pool"
export PROVIDER_ID="github-provider"
export SA_EMAIL="github-actions-sa-jtruc@utec-posgrado-01.iam.gserviceaccount.com"
export REPOSITORY="aldower/angular-cloud-run-v2"
```

Comprueba la cuenta de servicio y el pool existentes:

```bash
gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID"

gcloud iam workload-identity-pools describe "$POOL_ID" \
  --project="$PROJECT_ID" --location="global"
```

## 2. Habilitar las APIs necesarias

```bash
gcloud services enable \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  --project="$PROJECT_ID"
```

Si no tienes permiso para habilitar APIs, un administrador del proyecto debe hacerlo.

## 3. Crear el proveedor OIDC de GitHub

Primero comprueba si ya existe:

```bash
gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
  --project="$PROJECT_ID" --location="global" \
  --workload-identity-pool="$POOL_ID"
```

Si el resultado dice que no existe, créalo:

```bash
gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
  --project="$PROJECT_ID" \
  --location="global" \
  --workload-identity-pool="$POOL_ID" \
  --display-name="GitHub Actions OIDC" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.environment=assertion.environment" \
  --attribute-condition="assertion.repository == 'aldower/angular-cloud-run-v2' && assertion.environment == 'dev'"
```

La condición limita los tokens aceptados al repositorio indicado y a los jobs que usan el GitHub Environment `dev`. Los tres jobs del workflow deben conservar `environment: dev` y el permiso `id-token: write`.

## 4. Dar a la cuenta de servicio los permisos de despliegue

Estos comandos agregan roles necesarios al proyecto para desplegar en Cloud Run y publicar imágenes. Aplícalos solo si esos permisos aún no están asignados:

```bash
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/run.admin"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/artifactregistry.writer"
```

Permite que la cuenta de servicio de despliegue actúe como la cuenta de ejecución predeterminada de Cloud Run:

```bash
RUNTIME_SA="$PROJECT_NUMBER-compute@developer.gserviceaccount.com"

gcloud iam service-accounts add-iam-policy-binding "$RUNTIME_SA" \
  --project="$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/iam.serviceAccountUser"
```

Si el servicio usa una cuenta de ejecución personalizada, asigna `roles/iam.serviceAccountUser` sobre esa cuenta específica en lugar de la cuenta predeterminada.

## 5. Permitir que el repositorio impersonifique la cuenta de servicio

Este paso es esencial: autoriza al principal federado de este repositorio a utilizar la cuenta de servicio.

```bash
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$POOL_ID/attribute.repository/$REPOSITORY"
```

El comando requiere permiso para modificar la política IAM de la cuenta de servicio (`iam.serviceAccounts.setIamPolicy`). Si recibes `PERMISSION_DENIED`, un administrador debe ejecutar este comando o concederte temporalmente el permiso apropiado sobre esa cuenta. No hace falta otorgar `roles/owner`.

## 6. Obtener el nombre completo del proveedor

```bash
gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
  --project="$PROJECT_ID" \
  --location="global" \
  --workload-identity-pool="$POOL_ID" \
  --format="value(name)"
```

Copia el resultado completo. Tendrá este formato:

```text
projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/github-pool/providers/github-provider
```

Usa el valor real que devuelve el comando; no escribas literalmente `PROJECT_NUMBER`.

## 7. Configurar GitHub

En el repositorio, abre **Settings → Secrets and variables → Actions**.

### Repository variables

| Nombre | Valor |
| --- | --- |
| `GCP_WIF_PROVIDER` | Nombre completo devuelto en el paso 6 |
| `GCP_SERVICE_ACCOUNT` | `github-actions-sa-jtruc@utec-posgrado-01.iam.gserviceaccount.com` |

### Repository secrets

| Nombre | Valor |
| --- | --- |
| `ALUMNO_ID` | Alias único, en minúsculas y sin espacios |
| `ENVIRONMENT_NAME` | `dev` |

No crees `GCP_SA_KEY` ni generes una clave JSON.

## 8. Crear el GitHub Environment `dev`

1. En el repositorio, entra a **Settings → Environments**.
2. Crea el environment `dev` si aún no existe.
3. Si el laboratorio requiere aprobación manual, configura **Required reviewers**.
4. Guarda los cambios.

El workflow referencia este environment en los jobs que se autentican. La condición OIDC del proveedor depende de ese nombre exacto.

## 9. Verificar y ejecutar

Confirma que el proveedor existe:

```bash
gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
  --project="$PROJECT_ID" --location="global" \
  --workload-identity-pool="$POOL_ID"
```

Confirma que el principal tiene la vinculación IAM:

```bash
gcloud iam service-accounts get-iam-policy "$SA_EMAIL" \
  --project="$PROJECT_ID"
```

Luego ejecuta el workflow desde GitHub Actions haciendo push a `main` (o usa **Run workflow** si el workflow está configurado con `workflow_dispatch`). Revisa el log del paso **Google Auth (Workload Identity Federation)** antes de revisar el build y el despliegue a Cloud Run.

## Solución de problemas

- **`PERMISSION_DENIED` en `add-iam-policy-binding`:** tu usuario no puede editar la política IAM de esa cuenta de servicio. Pide al administrador que ejecute el paso 5.
- **`Provider not found`:** verifica los valores de `POOL_ID`, `PROVIDER_ID` y la ubicación `global`.
- **Error de condición OIDC:** confirma que el repositorio sea exactamente `aldower/angular-cloud-run-v2`, que el job tenga `environment: dev` y que el proveedor tenga el mapeo `attribute.environment=assertion.environment`.
- **Error al publicar la imagen:** comprueba `roles/artifactregistry.writer` y que el repositorio Artifact Registry `app-gemini` exista en `us-central1`.
- **Error al desplegar Cloud Run:** comprueba `roles/run.admin` y `roles/iam.serviceAccountUser` en la cuenta de ejecución usada por Cloud Run.

## Limpieza

No elimines el pool, el proveedor ni la cuenta de servicio compartida si otros alumnos o laboratorios los utilizan. Elimina únicamente los servicios e imágenes de prueba que te pertenezcan.
