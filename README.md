# Seekios 📱🎧

**Seekios** es un cliente open-source de Soulseek elegante y nativo para iOS, construido en Swift y SwiftUI. Diseñado originalmente como un reproductor de música, ha sido adaptado para convertirse en un **gestor universal de descargas y buscador P2P** directamente en tu iPhone o iPad.

---

## ✨ Características Principales

* **Búsqueda Universal de Archivos:** Ya no está limitado solo a música. Busca, filtra y descarga **cualquier tipo de archivo** (Videos, Archivos comprimidos `.zip`/`.rar`, Documentos, Libros, Imágenes, Apps y Audio Lossless/Lossy).
* **Gestor de Descargas Persistente:** El historial de descargas se guarda automáticamente en el disco de tu dispositivo. Si cierras la app o se interrumpe una descarga, al reabrirla podrás reanudarla con un solo toque (*Retry*).
* **Historial de Búsqueda Desplegable:** Al tocar la barra de búsqueda, se despliega tu historial reciente de términos buscados para repetirlos al instante.
* **Mini-Buscador en Vivo por Palabras Clave:** Cuenta con una barra de filtrado rápido justo encima de los resultados para acotar la búsqueda por extensiones, palabras clave o nombres de usuario sin necesidad de realizar una nueva petición a la red.
* **Explorador de Carpetas Raíz y Contenedoras:** Al pulsar sobre cualquier nivel de la ruta de un archivo o carpeta, puedes navegar libremente por los directorios compartidos del usuario (migas de pan / breadcrumbs) y descargar carpetas enteras o archivos individuales.
* **Barra de Progreso en Notificaciones y Live Activities:** Monitorea tus descargas en tiempo real mediante notificaciones del sistema con barra de progreso visual (▰▰▰▱▱) y soporte para Dynamic Island / Lock Screen.
* **Exportación Nativa (Share Sheet):** Envía tus archivos descargados a cualquier otra app, guárdalos en iCloud / Archivos o compártelos por AirDrop con el botón integrado de compartir.

---

## 🛠️ Compilación Automática (GitHub Actions)

Este repositorio incluye un flujo de trabajo preconfigurado en GitHub Actions (`.github/workflows/build.yml`) que compila automáticamente el proyecto y genera el archivo **`Seekios.ipa`** listo para firmar e instalar mediante SideStore, AltStore, Feather o LiveContainer.

Para lanzar una nueva versión en tu propio GitHub:
1. Ve a la pestaña **Releases** de tu repositorio.
2. Crea un nuevo Tag (etiqueta) que empiece por `v` (por ejemplo, `v1.0.0`).
3. Publica el Release y GitHub Actions generará y adjuntará automáticamente el archivo **`Seekios-1.0.0-unsigned.ipa`**.

---

## 📲 Instalación

1. Descarga el archivo `Seekios-unsigned.ipa` desde la sección de [Releases](https://github.com/SRJW/SEEKIOS/releases) de este repositorio.
2. Instálalo en tu dispositivo iOS utilizando tu instalador de confianza (SideStore, AltStore, LiveContainer, etc.).
3. ¡Inicia sesión con cualquier nombre de usuario de Soulseek (si no existe, se registrará automáticamente) y comienza a buscar y descargar!
