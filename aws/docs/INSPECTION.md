# Manual — Inspeccionar y volcar los recursos en Floci

Guía práctica para comprobar que cada recurso se creó y para ver sus datos,
directamente contra Floci (el emulador tipo LocalStack de este proyecto).

Todos los comandos son **solo lectura** salvo los de la sección "Probar el flujo".

---

## 0. Preparación (una vez por terminal)

Floci escucha en un único endpoint y no valida credenciales, pero el AWS CLI
necesita que existan. Exporta esto y usa `--endpoint-url` en cada llamada:

```bash
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
export E=http://localhost:4566          # endpoint de Floci
```

Para no repetir `--endpoint-url`, define un alias/función `awslocal`:

```bash
awslocal() { aws --endpoint-url="$E" "$@"; }
```

Comprobación rápida de que Floci está arriba y qué servicios corren:

```bash
curl -s "$E/_localstack/health" | python3 -m json.tool
```

> Nombres de recursos del proyecto (prefijo `event-pipeline`):
> cola `event-pipeline-access-events`, DLQ `…-dlq`, tabla
> `event-pipeline-access-events`, bucket `event-pipeline-raw-events`,
> función `event-pipeline-ingest-processor`, secreto
> `event-pipeline/ingestion-api-key`, API `event-pipeline-ingestion-api`.

---

## 1. Atajos: volcado completo y logs

Se añadieron dos targets al `Makefile`:

```bash
make dump    # vuelca TODOS los recursos y sus datos (script scripts/dump_resources.sh)
make logs    # sigue los logs del contenedor Floci (salida real de la Lambda + poller SQS)
```

`make dump` es la forma más rápida de "sacar un dump de cada recurso para comprobar
su creación". El resto del manual son los comandos individuales que ejecuta, por si
necesitas inspeccionar algo puntual.

---

## 2. Por servicio

### SQS (colas)
```bash
# URL de la cola
awslocal sqs get-queue-url --queue-name event-pipeline-access-events

# Atributos: profundidad de la cola, visibilidad, redrive hacia la DLQ
awslocal sqs get-queue-attributes \
  --queue-url "$E/000000000000/event-pipeline-access-events" \
  --attribute-names All

# Espiar mensajes SIN consumirlos de forma definitiva (vuelven tras el visibility timeout)
awslocal sqs receive-message \
  --queue-url "$E/000000000000/event-pipeline-access-events" \
  --max-number-of-messages 10 --visibility-timeout 0

# ¿Algo atascado en la DLQ? (mensajes que fallaron maxReceiveCount veces)
awslocal sqs get-queue-attributes \
  --queue-url "$E/000000000000/event-pipeline-access-events-dlq" \
  --attribute-names ApproximateNumberOfMessages
```
Qué mirar: `ApproximateNumberOfMessages` ≈ 0 en la cola principal tras procesar;
la DLQ debe estar en 0 si todo va bien.

### DynamoDB (tabla)
```bash
# Metadatos de la tabla (estado, clave, billing)
awslocal dynamodb describe-table --table-name event-pipeline-access-events

# Ver TODOS los items
awslocal dynamodb scan --table-name event-pipeline-access-events

# Solo el número de items
awslocal dynamodb scan --table-name event-pipeline-access-events --select COUNT

# Un item concreto por clave (event_id es un sha256 del payload)
awslocal dynamodb get-item --table-name event-pipeline-access-events \
  --key '{"event_id":{"S":"<hash>"}}'
```

### S3 (bucket de payloads crudos)
```bash
# ¿Existe el bucket?
awslocal s3api head-bucket --bucket event-pipeline-raw-events

# Versionado (debe estar Enabled)
awslocal s3api get-bucket-versioning --bucket event-pipeline-raw-events

# Listar objetos (se guardan como raw/YYYY/MM/DD/<hash>.json)
awslocal s3api list-objects-v2 --bucket event-pipeline-raw-events

# Ver el contenido de un objeto
awslocal s3 cp "s3://event-pipeline-raw-events/raw/2026/09/07/<hash>.json" - 
```

### Lambda (procesador)
```bash
# Configuración: runtime, handler, timeout, variables de entorno
awslocal lambda get-function-configuration --function-name event-pipeline-ingest-processor

# Mapeo con SQS (event source mapping): estado y batch size
awslocal lambda list-event-source-mappings --function-name event-pipeline-ingest-processor

# Invocar la función directamente con un evento SQS sintético (útil para ver errores
# de forma SÍNCRONA; devuelve FunctionError si el handler lanza excepción)
awslocal lambda invoke --function-name event-pipeline-ingest-processor \
  --cli-binary-format raw-in-base64-out \
  --payload '{"Records":[{"messageId":"m1","body":"{\"event_id\":\"probe\",\"user\":\"x\"}"}]}' \
  /tmp/out.json
cat /tmp/out.json
```
Qué mirar: `Runtime` = `python3.12`, `State` = `Active`, `Env.AWS_ENDPOINT_URL` =
`http://localhost.localstack.cloud:4566` (¡ojo!, no `localhost:4566`, ver §4).

### API Gateway (endpoint de ingesta)
```bash
# Descubrir el id de la REST API (es dinámico)
API_ID=$(awslocal apigateway get-rest-apis \
  --query "items[?name=='event-pipeline-ingestion-api'].id | [0]" --output text)

# Recursos / rutas
awslocal apigateway get-resources --rest-api-id "$API_ID"

# Integración de POST /events (debe apuntar a SQS SendMessage)
RES_ID=$(awslocal apigateway get-resources --rest-api-id "$API_ID" \
  --query "items[?path=='/events'].id | [0]" --output text)
awslocal apigateway get-integration --rest-api-id "$API_ID" --resource-id "$RES_ID" --http-method POST

# Stage y su deployment
awslocal apigateway get-stages --rest-api-id "$API_ID"

# API keys y usage plans
awslocal apigateway get-api-keys --include-values
awslocal apigateway get-usage-plans
awslocal apigateway get-usage-plan-keys --usage-plan-id <usage-plan-id>

# URL de invocación
echo "$E/restapis/$API_ID/local/_user_request_/events"
```

### Secrets Manager (API key)
```bash
awslocal secretsmanager describe-secret --secret-id event-pipeline/ingestion-api-key
# El valor (es la API key que el cliente manda en la cabecera x-api-key)
awslocal secretsmanager get-secret-value --secret-id event-pipeline/ingestion-api-key \
  --query SecretString --output text
```

### IAM (roles y políticas)
```bash
awslocal iam get-role --role-name event-pipeline-ingest-processor-role
awslocal iam list-role-policies --role-name event-pipeline-ingest-processor-role
awslocal iam get-role-policy --role-name event-pipeline-ingest-processor-role \
  --policy-name event-pipeline-ingest-processor-policy
```

### CloudWatch Logs (logs de la Lambda)
```bash
awslocal logs describe-log-groups --log-group-name-prefix /aws/lambda/event-pipeline-ingest-processor
awslocal logs describe-log-streams --log-group-name /aws/lambda/event-pipeline-ingest-processor \
  --order-by LastEventTime --descending
```
> **Aviso (Floci):** su API de Logs suele devolver `events: []` aunque la Lambda
> haya ejecutado. Para ver la salida REAL usa `make logs` (o `docker compose logs floci`), o
> `lambda invoke` (§Lambda) que devuelve el error de forma síncrona.

---

## 3. Probar el flujo de punta a punta (esto SÍ escribe datos)

```bash
API_ID=$(awslocal apigateway get-rest-apis \
  --query "items[?name=='event-pipeline-ingestion-api'].id | [0]" --output text)
URL="$E/restapis/$API_ID/local/_user_request_/events"
KEY=$(awslocal secretsmanager get-secret-value --secret-id event-pipeline/ingestion-api-key \
  --query SecretString --output text)

# 1) POST del evento (debe responder HTTP 200 {"status":"accepted"})
curl -s -w "\nHTTP %{http_code}\n" -X POST "$URL" \
  -H "x-api-key: $KEY" -H "Content-Type: application/json" \
  -d '{"event_id":"evt-1","user":"alice","action":"turnstile_in"}'

# 2) esperar el procesado asíncrono (API GW -> SQS -> Lambda) y comprobar destinos
sleep 8
awslocal dynamodb scan --table-name event-pipeline-access-events --select COUNT
awslocal s3api list-objects-v2 --bucket event-pipeline-raw-events --query "Contents[].Key"
```

Recorrido esperado: `POST → API Gateway → SQS → Lambda → DynamoDB (item) + S3 (objeto)`.

---

## 4. Notas específicas de Floci (importantes)

- **Endpoint desde dentro de la Lambda:** el código usa `AWS_ENDPOINT_URL`. Dentro
  del contenedor de la Lambda, `localhost` es la propia Lambda, no Floci. Por eso la
  variable apunta a `http://localhost.localstack.cloud:4566` (DNS interno de Floci
  hacia su contenedor). Con `localhost:4566` las llamadas a DynamoDB/S3 se cuelgan y
  la función hace timeout.
- **Logs:** la API de CloudWatch Logs de Floci suele venir vacía → usa `make logs`.
- **API key:** no se gestiona con `aws_api_gateway_api_key` (crashea el provider,
  ver `TROUBLESHOOTING.md`), sino vía `null_resource` + AWS CLI. Aun así la ves con
  `apigateway get-api-keys`.
- **Re-`apply` de API Gateway:** `GetIntegration` de Floci puede devolver `NotFound`
  en el refresh, así que un `terraform apply` sobre un stack ya levantado puede
  recrear la integración y, ocasionalmente, dejar el endpoint devolviendo
  `500 "No integration configured"` hasta el siguiente deploy. Un `make up` **limpio**
  (`make down && make up`) siempre deja el pipeline funcionando.

---

## 5. Inspección desde el lado de Terraform

```bash
cd terraform
terraform state list                       # recursos gestionados
terraform show                             # estado completo
terraform state show aws_lambda_function.ingest_processor
terraform output                           # invoke_url, nombres de cola/tabla/bucket, etc.
```
