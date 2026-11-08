# CuySearch Manager

App de barra de menú para macOS que arranca en tu Mac un servicio de búsqueda
web para agentes: el servicio HTTP de [CuySearch](https://github.com/0sw2ld0/CuySearch)
y un [SearXNG](https://github.com/searxng/searxng) propio. No necesita Docker,
Colima ni Valkey: todo corre como procesos nativos.

- Iniciar, detener y comprobar CuySearch y SearXNG.
- Copiar la URL del servicio (`http://127.0.0.1:8090`) para tus agentes.
- Ver la actividad y los errores recientes.
- Cambiar el puerto, la URL de SearXNG y la API key.
- Abrirse al iniciar sesión.

Si SearXNG no responde, CuySearch busca en DuckDuckGo, Bing, Brave, Mojeek y
Wikipedia desde tu conexión.

La app detecta los servicios que ya estén corriendo para no duplicarlos. Al
salir, detiene sólo lo que ella misma arrancó. Su identificador es
`com.cuycoders.CuySearchManager`.

## Compilar

Hace falta macOS 13 o posterior, Xcode o las Command Line Tools, y
[uv](https://docs.astral.sh/uv/).

```bash
./macos/CuySearchManager/build-app.sh
```

El script:

1. descarga Python 3.13 con `uv`;
2. clona SearXNG en la revisión fijada (`SEARXNG_COMMIT`) e instala sus dependencias;
3. instala `cuysearch[servicio]` desde la etiqueta publicada;
4. compila la app con SwiftPM y la firma en local (`codesign -s -`).

El resultado queda en `dist/CuySearch Manager.app`, autónomo, y puedes copiarlo
a `/Applications`. Las descargas se guardan en `.build-cache/` y no se suben al
repositorio.

Para empaquetar una copia local de CuySearch:

```bash
CUYSEARCH_SPEC="cuysearch[servicio] @ file:///ruta/a/CuySearch" ./macos/CuySearchManager/build-app.sh
```

Para desarrollar sin empaquetar, crea un `.venv` en la raíz con
`uv venv && uv pip install "cuysearch[servicio] @ git+https://github.com/0sw2ld0/CuySearch@v0.1.0"`
y ejecuta `swift run --package-path macos/CuySearchManager`. La app usará ese
`.venv` si no encuentra el Python empaquetado.

## Uso

```bash
curl http://127.0.0.1:8090/healthz
curl -X POST http://127.0.0.1:8090/v1/search \
  -H 'Content-Type: application/json' \
  -d '{"query": "httpx timeouts", "max_results": 5}'
```

La API completa está en el README de CuySearch. SearXNG queda limitado a
`http://127.0.0.1:8888`.

## Licencias

- El código de este repositorio (la app en Swift, los scripts y la
  configuración) es MIT; ver `LICENSE`.
- **SearXNG es AGPL-3.0-or-later.** La app lo empaqueta sin modificarlo y lo
  ejecuta como un proceso aparte. Para cumplir su licencia, el bundle incluye
  el código fuente exacto de la versión empaquetada, en
  `Contents/Resources/Sources/searxng-<commit>.tar.gz`. La revisión es la de
  `SEARXNG_COMMIT` en `build-app.sh`, y el código también está en
  https://github.com/searxng/searxng.
- `runtime/searxng/version_frozen.py` es un fichero de SearXNG (AGPL), generado
  para fijar su versión dentro del bundle.
- `runtime/searxng/settings.yml` y `limiter.toml` son la configuración que
  carga ese SearXNG.
- El bundle también incluye Python (licencia PSF) y las dependencias de
  CuySearch y SearXNG, cada una con su licencia dentro de su carpeta
  `*.dist-info`.
