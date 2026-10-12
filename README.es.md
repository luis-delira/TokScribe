[English](README.md) · **Español**

# TokScribe

App de macOS para transcribir videos de TikTok (y cualquier video o audio que tengas en el disco).
Todo el reconocimiento de voz ocurre **en tu Mac**, con el motor `SpeechAnalyzer` de macOS 26.
No se sube nada a ningún servidor y no hace falta descargar modelos de varios GB tipo Whisper.

## Cómo se ve el flujo

1. Pegas **uno o varios** enlaces de TikTok en la columna izquierda, uno por línea,
   y pulsas **Transcribir**. También puedes arrastrar varios videos o audios a la
   ventana, o añadirlos con ⌘O.
2. Cada enlace entra en la **cola** y se procesa por turno: `yt-dlp` descarga el
   archivo, AVFoundation extrae el audio a 16 kHz mono y el motor de voz del
   sistema lo transcribe con marcas de tiempo por frase.
3. Ves el progreso de cada elemento en la lista y, al hacer clic en cualquiera,
   su transcripción aparece a la derecha.
4. Exportas una transcripción suelta, o **todas de golpe** a una carpeta (un
   archivo por video), en `.txt`, en subtítulos `.srt` o en subtítulos web `.vtt`.

Puedes seguir añadiendo enlaces mientras la cola trabaja, saltar un elemento que
se atore, reintentar los que fallen y limpiar los terminados. El divisor entre
las dos columnas se puede arrastrar, por si quieres más espacio para el texto.

**Las transcripciones no se pierden al cerrar la app.** Al terminar cada video
se guardan en `~/Library/Application Support/TokScribe/library.json`, y al
volver a abrir la app aparecen en la cola listas para consultar o exportar. Se
guarda *después de cada video*, no al final de la tanda, para que una caída a
mitad de una cola larga no borre lo ya hecho. Se conservan las últimas 300 y
puedes borrar el historial desde **Archivo → Borrar historial guardado**.

Solo se guarda el **texto**: el video y el audio intermedio se borran igual que
antes.

## Requisitos

- macOS 26 o posterior (el motor de transcripción es nuevo de esta versión).
- Xcode para compilar en macOS 27 o posterior (las Command Line Tools ya no traen las macros de SwiftUI; en macOS 26 bastan). `build.sh` usa Xcode automáticamente si está instalado.
- `yt-dlp`, solo para la descarga desde una URL. Puede ir **dentro de la app**
  (ver abajo) o instalado en el sistema con `brew install yt-dlp`.

**ffmpeg no hace falta.** La conversión de audio es nativa, con AVFoundation.
Si de todos modos lo tienes instalado, la app lo usa como respaldo para formatos
raros que macOS no sepa abrir por su cuenta, como `.webm`.

## Compilar

```bash
./build.sh
```

Genera `build/TokScribe.app`. Para instalarla:

```bash
cp -R build/TokScribe.app /Applications/
```

## Empaquetar yt-dlp dentro de la app

Para repartir la app a alguien que no tiene Homebrew:

```bash
./bundle-deps.sh && ./build.sh
```

`bundle-deps.sh` baja el binario autónomo oficial de yt-dlp a `Resources/bin/` y
`build.sh` lo mete en `TokScribe.app/Contents/Resources/bin/`. La app siempre
prefiere esa copia y solo recurre al sistema si no la encuentra, así que la app
resultante funciona en un Mac recién sacado de la caja.

Vuelve a correr `bundle-deps.sh` de vez en cuando: TikTok cambia por dentro con
frecuencia y yt-dlp se actualiza para seguirle el paso.

## Licencias, si piensas venderla

- **yt-dlp** es Unlicense (dominio público): puedes redistribuirlo sin condiciones.
- **ffmpeg** no se empaqueta a propósito. El de Homebrew viene compilado con
  `--enable-gpl`, y meterlo en una app de código cerrado infringiría la GPL.
  Por eso la conversión se hace con AVFoundation.
- El motor de voz es parte de macOS y no añade obligaciones.

La Mac App Store no es una vía posible: exige *sandbox*, y una app en sandbox no
puede ejecutar binarios externos como yt-dlp. La distribución realista es directa,
con la app notarizada mediante una cuenta de Apple Developer.

La app se firma localmente (ad-hoc). La primera vez, si macOS se queja por venir de un
desarrollador no identificado, ábrela con clic derecho → **Abrir**.

## Idiomas

El menú de idioma se llena con los idiomas que soporta el motor del sistema. La primera
transcripción en un idioma nuevo descarga su modelo (unos segundos) y queda instalado
para siempre.

**Automático** (opción por defecto): antes de transcribir cada video, la app toma una
muestra corta del audio y prueba con ella los idiomas **que ya tienes instalados**,
quedándose con el que mejor encaja. Combina dos señales: la confianza que reporta cada
modelo de voz y si el texto resultante es coherente según NaturalLanguage. Así puedes
mezclar en una misma cola videos en español y en inglés, y cada uno sale en su idioma.

La detección solo elige entre idiomas ya instalados, para no disparar descargas de varios
GB sin avisar. Si solo tienes uno instalado, no hay nada que distinguir: instala el otro
transcribiendo una vez con él elegido a mano, y a partir de ahí el modo automático lo
tendrá en cuenta. Si sabes de antemano el idioma, elígelo fijo y te ahorras el sondeo.

## Por qué se pide H.264 y no «la mejor calidad»

TikTok ofrece cada video en varios formatos. Los codificados en **H.265
(`bytevc1`)** llegan **sin pista de audio**, aunque yt-dlp anuncia `acodec=aac`
para ellos. Como suelen ser los de mayor resolución, un selector normal los
elige y el archivo llega mudo: la app fallaba con «no contiene ninguna pista de
audio» en videos que sí tienen sonido.

Por eso `formatSelectors` en `MediaFetcher.swift` pide **H.264 primero**. Y si
aun así el archivo llega sin audio, se reintenta automáticamente con otro
formato antes de darse por vencido. Solo cuando ningún formato trae sonido se
avisa al usuario, que es el caso real de una galería de fotos o un video mudo.

Para diagnosticar un video concreto:

```bash
yt-dlp -F "<url>"
```

Si en la columna `ACODEC` todo dice `aac` pero el archivo descargado no tiene
audio, es este mismo problema. Se comprueba con:

```bash
ffprobe -v error -show_entries stream=codec_type,codec_name -of csv=p=0 archivo.mp4
```

## Cookies

TikTok a veces bloquea descargas anónimas ("Your IP address is blocked from accessing this post").
En ese caso elige tu navegador en el menú **Cookies**: yt-dlp reutiliza tu sesión abierta de TikTok.
Con Safari, macOS pedirá acceso a disco completo para la terminal o la app.

## Diagnóstico

`build/tokscribe-cli` transcribe un archivo directamente desde la terminal; sirve para
distinguir si un problema viene de la descarga o del reconocimiento de voz:

```bash
./build/tokscribe-cli /ruta/al/audio.wav es-MX
```

## Estructura

| Archivo | Qué hace |
| --- | --- |
| `Sources/TokScribeApp.swift` | Punto de entrada y menús |
| `Sources/ContentView.swift` | Interfaz de dos columnas: cola y transcripción |
| `Sources/AppModel.swift` | La cola, su procesamiento en serie y la exportación |
| `Sources/TranscriptionJob.swift` | Un elemento de la cola, con su estado y resultado |
| `Sources/MediaFetcher.swift` | Ejecuta yt-dlp, progreso y traducción de errores |
| `Sources/AudioExtractor.swift` | Extrae audio a WAV 16 kHz con AVFoundation |
| `Sources/Transcriber.swift` | Motor de voz on-device, segmentación y formatos de salida |
| `Sources/LanguageDetector.swift` | Adivina el idioma sondeando modelos + NaturalLanguage |
| `Sources/LibraryStore.swift` | Guarda y relee las transcripciones terminadas |
| `Tools/MakeIcon.swift` | Dibuja el icono de la app |
| `Tools/TranscribeCLI.swift` | Diagnóstico: transcribe un archivo suelto |
| `Tools/BatchTest.swift` | Diagnóstico: ejercita la cola con varios archivos |
| `Tools/DetectTest.swift` | Diagnóstico: reporta el idioma detectado por archivo |
| `Tools/PersistTest.swift` | Diagnóstico: simula cerrar y reabrir la app |

Los archivos de `Tools/` no entran en la app; se compilan aparte cuando hacen
falta. Por ejemplo, para comprobar la persistencia:

```bash
xcrun swiftc -parse-as-library -swift-version 5 \
  -target arm64-apple-macos26.0 -sdk "$(xcrun --show-sdk-path)" \
  Sources/AppModel.swift Sources/TranscriptionJob.swift Sources/Transcriber.swift \
  Sources/AudioExtractor.swift Sources/LanguageDetector.swift \
  Sources/MediaFetcher.swift Sources/LibraryStore.swift Tools/PersistTest.swift \
  -o build/persist-test && codesign --force --sign - build/persist-test
```

`PersistTest` respalda tu biblioteca real antes de correr y la restaura al
terminar, así que no pierde tu trabajo.

Descarga videos solo cuando tengas derecho a hacerlo; el contenido de TikTok es de sus autores.
