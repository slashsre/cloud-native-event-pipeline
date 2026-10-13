# Troubleshooting — `make up` falla con "Plugin did not respond" / crash del provider AWS

## 1. Síntoma

Al ejecutar `make up` (que corre `terraform apply`), el `apply` aborta con varios errores
`Error: Plugin did not respond` y, al final, un **panic** del provider:

```
Error: Plugin did not respond
  with aws_api_gateway_api_key.client,
  on api_gateway.tf line 85 ...
  The plugin encountered an error, and failed to respond to the
  plugin.(*GRPCProvider).ApplyResourceChange call.

Stack trace from the terraform-provider-aws_v3.76.1_x5 plugin:

panic: runtime error: invalid memory address or nil pointer dereference
[signal SIGSEGV: segmentation violation code=0x2 addr=0x0 ...]

goroutine 151 [running]:
.../apigateway.resourceAPIKeyRead(...)
  .../apigateway/api_key.go:145 +0xb54
.../apigateway.resourceAPIKeyCreate(...)
  .../apigateway/api_key.go:97 +0x688
```

Los demás recursos (`aws_dynamodb_table`, `aws_s3_bucket`, `aws_iam_role`,
`aws_secretsmanager_secret`, `aws_sqs_queue`, …) también reportan
`Plugin did not respond`, **pero eso es daño colateral**: Terraform los aplica en
paralelo dentro del **mismo proceso de plugin**. Cuando la goroutine de la API key
hace panic, el proceso del provider muere y todas las peticiones en vuelo fallan a la vez.

> El recurso que realmente rompe es **uno solo**: `aws_api_gateway_api_key.client`.

---

## 2. Causa raíz

El stack trace apunta a `apigateway/api_key.go:145`, dentro de `resourceAPIKeyRead`
(que `resourceAPIKeyCreate` invoca justo después de crear la key). En **todas** las
versiones del provider ese código hace:

```go
d.Set("value", apiKey.Value)
if err := d.Set("created_date", apiKey.CreatedDate.Format(time.RFC3339)); err != nil { ... }
//                              ^^^^^^^^^^^^^^^^^^^ *time.Time
```

`apiKey.CreatedDate` es un puntero `*time.Time`. Si la respuesta de la API **no trae**
ese campo, el puntero es `nil` y llamar `.Format(...)` sobre `nil` provoca el
`nil pointer dereference` (SIGSEGV) → panic → muere el plugin.

### Validación A — qué campos devuelve Floci al crear una API key

Floci corriendo (imagen pineada en el `Makefile`):

```
$ docker ps --filter name=floci --format '{{.Image}} {{.Status}}'
floci/floci:2.0.1  Up (healthy)

$ curl -s http://localhost:4566/_localstack/info
{"version":"2.0.1","original_edition":"floci-always-free","edition":"community"}
```

Creando una API key directamente contra Floci (mismo endpoint que usa Terraform):

```
$ aws --endpoint-url=http://localhost:4566 apigateway create-api-key \
      --name diag-test-key --value "diagtestkey1234567890abcdef" --enabled

{
    "id": "diagtestkey1234567890abcdef",
    "value": "diagtestkey1234567890abcdef",
    "name": "diag-test-key",
    "enabled": true
}
```

**Faltan `createdDate` y `lastUpdatedDate`.** AWS real siempre los devuelve; Floci
(LocalStack 2.0.1 community) no. Ese es el campo `nil` que hace panic al provider.

Nota: el `create-api-key` por CLI **funciona bien**. Lo que rompe es únicamente el
*read-back* que hace el provider tras crear el recurso.

### Validación B — todas las versiones del provider desreferencian el puntero sin protección

Revisando el código fuente de `internal/service/apigateway/api_key.go`:

| Versión provider | Línea de `resourceAPIKeyRead` | ¿Protege contra nil? |
|---|---|---|
| v3.76.1 (la pineada) | `d.Set("created_date", apiKey.CreatedDate.Format(time.RFC3339))` | ❌ No |
| v4.67.0 | `d.Set("created_date", apiKey.CreatedDate.Format(time.RFC3339))` | ❌ No |
| v5.31.0 | `d.Set("created_date", apiKey.CreatedDate.Format(time.RFC3339))` | ❌ No |
| v5.83.0 (SDK Go v2) | `d.Set(names.AttrCreatedDate, apiKey.CreatedDate.Format(time.RFC3339))` | ❌ No |

Ninguna versión hace `if apiKey.CreatedDate != nil` ni usa `aws.ToTime(...)`. Por tanto
**cambiar la versión del provider (subir o bajar) NO arregla el problema**.

### Validación C — el comportamiento de Floci no depende del tag de imagen

Se probaron otras imágenes de Floci en un puerto aparte (`4567`), creando una API key:

| Imagen | `version` reportada | ¿Devuelve `createdDate`? |
|---|---|---|
| `floci/floci:2.0.1`        | 2.0.1 community | ❌ No |
| `floci/floci:2.0.1-compat` | 2.0.1 community | ❌ No |
| `floci/floci:latest`       | 2.0.1 community | ❌ No |

Todas omiten `createdDate`. **Cambiar el tag de imagen tampoco lo arregla.**

---

## 2.b. Por qué el SDK/CLI directo NO rompe, pero Terraform sí

El crash no lo dispara la llamada a la API, sino el paso en que **Terraform mapea la
respuesta a su estado tipado**.

- **SDK/CLI directo** (`aws apigateway create-api-key`): el SDK deserializa la respuesta
  y deja `CreatedDate = nil` (puntero vacío). El CLI solo serializa los campos presentes
  y termina. **Nadie llama `.Format()` sobre ese puntero → no pasa nada.** Es justo lo que
  demostró la Validación A: el `create-api-key` por CLI funciona.

- **Terraform**: el provider (que internamente **también usa** `aws-sdk-go`; no es
  "SDK vs no-SDK") hace, tras el `Create`, un **read-back** para volcar al `state` **todos**
  los atributos del esquema, incluido el atributo `Computed` `created_date`. Ahí ejecuta
  `d.Set("created_date", apiKey.CreatedDate.Format(time.RFC3339))` sobre un puntero `nil`
  → SIGSEGV.

Matices:

1. La diferencia real no es "usar SDK o no" — el provider está construido sobre el mismo
   SDK. Es **qué se hace con la respuesta**: el CLI no toca `createdDate`; el provider está
   obligado a leerlo para persistir el `state`.
2. No hace falta un `apply` nuevo: cualquier operación que fuerce el *read* del recurso ya
   en estado (`terraform refresh`/`plan`, o el read post-create) dispara el mismo panic.
3. El fallo de fondo es un **defecto del provider** (desreferencia sin comprobar `nil`),
   *provocado* por la respuesta incompleta de Floci. Por eso ninguna versión del provider
   lo evita y el arreglo real está en Floci (devolver el campo) o en no gestionar ese
   recurso vía Terraform.

---

## 3. Por qué el comentario de `providers.tf` es engañoso

`terraform/providers.tf` dice:

```hcl
# Pinned: versions 4.x and 5.x crash against Floci when reading back
# resources after create due to nil pointer dereferences.
# Version 3.76.1 is the last stable 3.x release and works with Floci 2.0.x.
version = "= 3.76.1"
```

- La parte de "4.x y 5.x crashean por nil pointer dereferences" es **cierta**.
- La parte de "3.76.1 … works with Floci" es **falsa**: 3.76.1 crashea exactamente igual,
  por la misma línea (`api_key.go:145`).

El comentario induce a perder tiempo probando versiones del provider. El problema real
está en el **dato que devuelve Floci**, no en el provider.

---

## 4. Opciones de arreglo

El objetivo: evitar que el provider ejecute el *read-back* que desreferencia
`CreatedDate == nil`, sin perder el mecanismo de API key del diseño.

### Opción 1 (recomendada) — gestionar la API key fuera del provider  ✅ IMPLEMENTADA

Sustituir los recursos que crashean (`aws_api_gateway_api_key.client` y su
`aws_api_gateway_usage_plan_key.client`) por un `null_resource` con `local-exec` que
use el AWS CLI (que sí funciona, ver Validación A). El provider nunca vuelve a leer la
key, así que no hay panic. El resto del stack (SQS, DynamoDB, S3, IAM, Secrets, Lambda,
usage plan) se sigue gestionando con Terraform con normalidad.

Ventaja: se conserva el diseño (API key + usage plan) y sigue funcionando en Floci 2.0.1.
Desventaja: introduce dependencia del AWS CLI y sale del modelo declarativo puro para ese recurso.

**Implementación** (`terraform/api_gateway.tf` + `terraform/providers.tf`):
- Se añadió el provider `hashicorp/null` (`~> 3.2`).
- Se eliminaron `aws_api_gateway_api_key.client` y `aws_api_gateway_usage_plan_key.client`.
- Se añadió `null_resource.client_api_key` que, vía `local-exec`:
  - crea la API key con el valor de `random_password.api_key` (idempotente: reutiliza la
    key si ya existe, con filtro JMESPath del lado cliente),
  - la asocia al usage plan (`create-usage-plan-key`),
  - y en `destroy` la borra (best-effort).
  El secreto se pasa por variables de entorno, no en la línea de comando.

**Validación (Floci reseteado, `make down && make up`):**
```
Apply complete! Resources: 24 added, 0 changed, 0 destroyed.
null_resource.client_api_key: Creation complete after 8s
```
```
# API key creada y enganchada al usage plan
get-api-keys        -> event-pipeline-client-key (enabled)
get-usage-plan-keys -> event-pipeline-client-key (API_KEY)

# POST end-to-end con x-api-key (valor leído de Secrets Manager)
curl -X POST .../local/_user_request_/events -H "x-api-key: <key>" -d '{...}'
HTTP 200
{"status": "accepted"}          # integración API Gateway -> SQS OK
```
Ya **no hay panic**; el `apply` completa entero.

> Nota (problema **independiente** detectado en la validación end-to-end): la Lambda
> `ingest_processor` falla al importar en el runtime `python3.9` con
> `TypeError: unsupported operand type(s) for |: 'type' and 'type'`. Causa: `requirements.txt`
> pinea `boto3>=1.34.0` (sin techo) y `scripts/build_lambda.sh` instala en el host sin fijar
> plataforma/versión, arrastrando un `urllib3` 2.x que usa sintaxis de unión `X | Y` en
> runtime (solo válida en 3.10+). El mensaje llega a SQS pero la Lambda no persiste en
> DynamoDB/S3. Esto **no** tiene relación con la API key ni con el fix de Option 1.
> Fix sugerido: subir el runtime a `python3.12`/`3.11`, o acotar deps (`urllib3<2` + boto3
> compatible con 3.9) y construir con `--python-version 3.9 --only-binary=:all:`.

### Opción 2 — desactivar la API key solo en local

Poner `api_key_required = false` en `aws_api_gateway_method.post_events` y eliminar
`aws_api_gateway_api_key`, `aws_api_gateway_usage_plan` y `aws_api_gateway_usage_plan_key`.
(Se mantiene `random_password` + Secrets Manager como fuente de verdad de la clave).

Justificación: LocalStack/Floci community **no aplica** realmente la validación de API
keys en las REST API, así que en local no aporta seguridad; solo rompe el `apply`.
Desventaja: se aleja del diseño "producción" que exige la key.

### Opción 3 — imagen de Floci que sí devuelva `createdDate`

Sería la más limpia (no tocar Terraform), pero **ninguna imagen de Floci disponible
devuelve el campo** (Validación C). Descartada salvo que exista una edición no-community
que lo popule.

---

## 4.b. Referencias en el repositorio de Floci (`github.com/floci-io/floci`)

Floci es open source (fork/relevo de LocalStack tras el cierre de su edición community
en marzo de 2026). No existe un issue para el caso **exacto** ("`CreateApiKey` omite
`createdDate` → nil pointer en el provider"), pero **este patrón de bug está bien
documentado** — Floci omite campos de respuesta de API Gateway que el provider de AWS
espera:

| Issue | Título | Estado | Relación |
|---|---|---|---|
| [#999](https://github.com/floci-io/floci/issues/999)   | ApiGateway (v1) GetRestApi/PutRestApi missing endpointConfiguration in response (**causes Terraform provider crash**) | Cerrado | **Mismo modo de fallo**: campo ausente en respuesta apigateway v1 → crash del provider |
| [#1676](https://github.com/floci-io/floci/issues/1676) | apigateway: CreateApiKey drops "tags" and GetApiKey is not implemented (404) | Cerrado | Específico del recurso **API key** (antes GetApiKey daba 404; hoy responde, pero sin `createdDate`) |
| [#2804](https://github.com/floci-io/floci/issues/2804) | apigateway: RestApi response omits `apiStatus`, hangs terraform-provider-aws's create waiter (fix: PR [#2816](https://github.com/floci-io/floci/pull/2816)) | Cerrado | Mismo patrón, distinto campo; afecta a providers 5.x (SDK v2) |

**Ojo:** esos issues están cerrados como resueltos, pero el `Makefile` pinea
`floci/floci:2.0.1`, y se comprobó (Validación C) que `2.0.1` y `latest` siguen
reportando versión `2.0.1` y siguen **sin** devolver `createdDate` en las API keys. El
caso concreto de `createdDate` parece **no reportado / no incluido** en la imagen del
challenge. La dirección de fix propuesta por el propio proyecto en casos análogos
(p. ej. #2804) es *"always return the field on create/read responses"*; aquí sería que
`CreateApiKey`/`GetApiKey` devuelvan `createdDate`/`lastUpdatedDate`.

## 5. Resumen ejecutivo

- **Recurso culpable:** `aws_api_gateway_api_key.client` (el resto son daño colateral por
  compartir proceso de plugin).
- **Causa raíz:** Floci 2.0.1 no devuelve `createdDate`/`lastUpdatedDate` al crear una API
  key; el provider AWS hace `CreatedDate.Format()` sobre un puntero `nil` → SIGSEGV.
- **Lo que NO arregla:** cambiar la versión del provider (todas 3.x/4.x/5.x fallan igual)
  ni cambiar el tag de imagen de Floci.
- **Lo que SÍ arregla:** no dejar que el provider lea de vuelta ese recurso — gestionar la
  API key por CLI (Opción 1) o desactivarla en local (Opción 2).

---

## 6. Cambios aplicados finalmente (estado actual del repo)

Tras validar Opción 1, se decidió modernizar el stack. Resumen de todo lo aplicado:

1. **API key vía `null_resource`** (Opción 1, §4). Se mantiene incluso tras subir el
   provider, porque el crash de `createdDate` afecta a *todas* las versiones del provider.
2. **Provider AWS `= 3.76.1` → `~> 5.0`** (se resolvió a `5.100.0`). El pin 3.76.1 solo
   existía por el crash de la API key, ya sorteado. Ajustes por breaking changes de 5.x en
   `providers.tf`: `s3_force_path_style` → `s3_use_path_style`, y clave de endpoint
   `cloudwatchlogs` → `logs`. **Nota:** contra Floci 2.0.1 el provider 5.x creó la REST API
   sin colgarse en el waiter de `apiStatus` (#2804) ni crashear por `endpointConfiguration`
   (#999); esos issues no se manifestaron en este entorno.
3. **Runtime de la Lambda `python3.9` → `python3.12`** (`lambda.tf`). Resuelve el
   `TypeError: unsupported operand type(s) for |` (urllib3 2.x usa `X | Y` en runtime, solo
   válido en 3.10+). Requería el provider nuevo: 3.76.1 solo validaba runtimes hasta 3.9.
4. **Endpoint interno de la Lambda** (`lambda.tf`): `AWS_ENDPOINT_URL` pasó de
   `http://localhost:4566` a `http://localhost.localstack.cloud:4566`. Desde el contenedor
   de la Lambda, `localhost` es la propia Lambda; con el hostname interno de Floci la función
   alcanza DynamoDB/S3 (antes hacía timeout a los 15 s).
5. **Deployment de API Gateway** (`api_gateway.tf`): `triggers.redeployment = timestamp()`
   + `depends_on` explícito a la integración. Ver caveat abajo.

**Validación end-to-end (make down && make up):** `POST → HTTP 200 {"status":"accepted"}`,
1 item en DynamoDB y 1 objeto en S3. Verificado con `make dump`.

### Caveat conocido — re-`apply` de API Gateway en Floci
`GetIntegration` de Floci devuelve `NotFound` en el refresh, así que Terraform recrea
`aws_api_gateway_integration.sqs` en cada `apply`. Recrear la integración invalida el stage
salvo que se redepliegue, y el timing de recrear-integración + redeploy + actualizar-stage
en Floci es **racy**: un `terraform apply` repetido sobre un stack ya levantado puede dejar
el endpoint devolviendo `500 "No integration configured"` de forma intermitente. Un
**`make up` limpio (`make down && make up`) siempre deja el pipeline funcionando**. Si se
necesitara re-`apply` idempotente de verdad, la vía robusta sería gestionar también el
cableado de API Gateway (método/integración/deployment) fuera del provider (CLI/`null_resource`),
igual que la API key.

## 7. Inspección / dump de recursos
Ver **`INSPECTION.md`**. Atajos: `make dump` (vuelca todos los recursos y sus datos) y
`make logs` (salida real de la Lambda vía `docker logs`, ya que la API de Logs de Floci
suele venir vacía).
