# CaribeShop

## Demostración de Key Vault

Se requiere Terraform 1.11 o una versión posterior para la entrada de secreto
de solo escritura.

El conjunto de escalado de máquinas virtuales lee el secreto
`caribeshop-demo` mediante su identidad administrada asignada por el sistema.
Key Vault permite el acceso desde la subred de las VM y desde la dirección IPv4
pública del operador de Terraform (`/32`); todo el demás acceso de red se
deniega. La identidad de la VM recibe solamente el rol **Key Vault Secrets
User**. La identidad de Terraform recibe el rol **Key Vault Secrets Officer**
en este almacén para aprovisionar y rotar el secreto de demostración.
Incremente `value_wo_version` en `terraform/main.tf` al rotar el valor del
secreto de solo escritura.

Antes de ejecutar Terraform, proporcione estas entradas locales:

- `operator_ipv4_cidr`: la dirección IPv4 pública actual del operador en
  notación `/32`.
- `demo_secret_expires_at`: una fecha y hora futura con formato RFC3339.
- `demo_secret_value`: un valor de demostración generado localmente con al
  menos 16 caracteres. Proporcione el valor mediante
  `TF_VAR_demo_secret_value` o mediante un archivo tfvars local ignorado por
  Git; nunca lo confirme ni lo imprima.

El secreto utiliza el argumento `value_wo` de solo escritura del proveedor,
por lo que su valor no se almacena en el estado de Terraform. Proteja igualmente
el estado remoto y las entradas locales de Terraform.

Después del despliegue, `terraform output -raw secret_check_url` devuelve un
endpoint que informa únicamente la longitud del secreto y una huella SHA-256
truncada. Nunca devuelve el valor del secreto.

El endpoint y el proxy se instalan mediante cloud-init. Antes de probar el
endpoint, las instancias existentes del VMSS deben recibir el modelo actualizado
y volver a crearse o reemplazarse mediante una actualización controlada, una
instancia a la vez.

## Políticas y registros de auditoría de Key Vault

El grupo de recursos tiene una política Deny que rechaza los almacenes Key Vault
a menos que tengan habilitados tanto la autorización RBAC como la protección
contra eliminaciones. Los registros `AuditEvent` de Key Vault se envían durante
30 días a la tabla `AZKVAuditLogs` del área de trabajo `law-caribeshop`.

Utilice esta consulta para verificar las lecturas del secreto realizadas por la
identidad administrada del VMSS:

```kusto
AZKVAuditLogs
| where OperationName == "SecretGet"
| where tostring(Identity) contains "<VMSS principal ID>"
| project TimeGenerated, OperationName, ResultType, CallerIpAddress, Identity
| order by TimeGenerated desc
```

## Escalado automático del VMSS

El perfil normal mantiene entre una y dos instancias `Standard_D2s_v7`, dentro
de la cuota actual de cuatro vCPU. Para realizar una prueba de carga de Locust
con una sola instancia, establezca temporalmente
`minimum = maximum = default = 1`, aplique los cambios y confirme que existe
exactamente una instancia antes de iniciar la carga.

Locust solicita `/`, la página principal estática servida por Nginx. Esto
aisla la ruta balanceador de carga/Nginx/VM del servicio Python y evita una
lectura de Key Vault por solicitud. No mide la ruta de negocio
`/secret-check` ni la capacidad de Key Vault; mantenga separados esos resultados
de extremo a extremo. El usuario de Locust espera entre 0.5 y 1 segundo entre
solicitudes para generar una tasa de solicitudes moderada.

En Windows, prepare e inicie Locust desde la raíz del repositorio:

```powershell
py -m venv .venv-load
.\.venv-load\Scripts\python.exe -m pip install -r requirements-loadtest.txt
$baseUrl = (terraform -chdir=terraform output -raw secret_check_url) -replace '/secret-check$', ''
.\.venv-load\Scripts\python.exe -m locust -f locustfile.py --host $baseUrl
```

Abra `http://localhost:8089`, comience con un número reducido de usuarios y
auméntelos gradualmente con una tasa de inicio baja. Mantenga cada nivel el
tiempo suficiente para que la latencia se estabilice. Registre los usuarios,
la tasa de inicio, las solicitudes por segundo (RPS), el p95 y los fallos. El
resultado sostenible es el RPS más alto con un p95 igual o inferior a un segundo
y sin errores relevantes; deténgase si aparecen errores o limitación por parte
de Key Vault.

### Observaciones preliminares

La fase exploratoria con 900 usuarios superó el umbral p95, pero estos resultados
no constituyen una prueba definitiva de capacidad: se observó Locust en dos
procesos de Python durante ese aumento y los valores de RPS informados incluyen
el tiempo de incremento, no únicamente una meseta estable.

| Usuarios | Solicitudes | RPS promedio | p95 | Fallos |
| ---: | ---: | ---: | ---: | ---: |
| 700 | 168,000 | 545.33 | 940 ms | 0 |
| 725 | 162,610 | 576.90 | 710 ms | 0 |
| 900 | 72,515 | 521.56 | 1,100 ms | 362 errores de conexión |

Repita la prueba con un único proceso de Locust y mesetas de duración fija
antes de informar el RPS sostenible máximo. El resultado con 900 usuarios superó
el umbral de latencia y no fue sostenible debido a los errores de conexión.

Después de la prueba de carga, restaure la capacidad con
`minimum = 1`, `maximum = 2` y `default = 1`, y aplique los cambios. Esto
permite la expansión dentro de la cuota actual de cuatro vCPU. El perfil agrega
una instancia cuando la CPU promedio supera el 70 % durante cinco minutos, con
un período de espera de cinco minutos, y elimina una solamente cuando la CPU
promedio permanece por debajo del 30 % durante diez minutos, con un período de
espera de diez minutos. `ignore_changes = [instances]` permite que Azure
Autoscale gestione la capacidad sin que Terraform la restablezca.

## Reparaciones automáticas del VMSS

Despliegue las reparaciones automáticas por fases porque este VMSS utiliza el
modo de actualización Manual:

1. Aplique `health_probe_id` y restablezca el máximo de escalado automático a 2
   mientras las reparaciones automáticas aún no están habilitadas.
2. Aplique el modelo más reciente del VMSS a todas las instancias existentes
   con `az vmss update-instances` y confirme que cada instancia tiene el modelo
   más reciente.
3. Agregue y aplique la política de reparación automática.

Las reparaciones automáticas utilizan la prueba de estado del balanceador de
carga en `/health`. Una respuesta correcta es HTTP 200; el marcador de prueba
`/var/www/unhealthy` hace que el endpoint devuelva HTTP 503. Con el período de
gracia de 10 minutos, Azure reinicia una instancia no saludable. Esto evita
necesitar cuota para una VM temporal de reemplazo, pero la instancia no está
disponible mientras se reinicia. El marcador de prueba persiste después de los
reinicios, por lo que debe utilizar una falla temporal del servicio, por ejemplo
detener Nginx, al probar la recuperación.

Para una prueba de reparación, conserve disponible una segunda instancia
correcta para reducir la interrupción. Restaure el perfil normal de escalado
automático después de la prueba con una sola instancia y antes de probar las
reparaciones.
