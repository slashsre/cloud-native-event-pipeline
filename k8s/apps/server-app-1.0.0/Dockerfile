# 1. Imagen base mínima y versionada explícitamente
FROM python:3.13-slim

# 2. Variables de entorno estándar
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    APP_HOME=/app

WORKDIR ${APP_HOME}

# 3. Crear usuario sin privilegios
RUN groupadd -g 10001 appgroup && \
    useradd -u 10001 -g appgroup -s /bin/sh -d ${APP_HOME} appuser

# 4. Capa de dependencias optimizada para caché
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 5. Copiar código fuente
COPY . .

# 6. Asignar permisos al usuario no-root
RUN chown -R appuser:appgroup ${APP_HOME}

# 7. Cambiar al usuario sin privilegios
USER 10001

# 8. Documentar puerto expuesto / Lo manejamos desde el Deployment de K8S
# EXPOSE 5001

# 9. Ejecución como PID 1 (formato exec)
CMD ["python", "server.py"]