|"""
relaxPlayer - Reproductor Multimedia Nativo (Android y PC)
Fluidez total (60 FPS), fondo 100% opaco sin transparencias al subir,
audio nativo compatible con Flet 1.1+ y control de volumen en vivo al deslizar.

Dependencias (pyproject.toml):
    flet, flet-audio, flet-video, flet-permission-handler, mutagen
"""

import asyncio
import base64
import dataclasses
import datetime
import inspect
import json
import os
import random
import sys
import threading
import time
import flet as ft


def obtener_dir_app() -> str:
    if getattr(sys, "frozen", False):
        return os.path.dirname(os.path.abspath(sys.executable))
    return os.path.dirname(os.path.abspath(__file__))


BASE_DIR = obtener_dir_app()
DATA_FILE = os.path.join(BASE_DIR, "relaxplayer_datos.json")

# --- Compatibilidad Flet 1.x ---
Icons = getattr(ft, "Icons", None) or getattr(ft, "icons")
BoxFitEnum = getattr(ft, "BoxFit", None) or getattr(ft, "ImageFit", None)
FIT_COVER = getattr(BoxFitEnum, "COVER", "cover") if BoxFitEnum else "cover"
FIT_CONTAIN = getattr(BoxFitEnum, "CONTAIN", "contain") if BoxFitEnum else "contain"

# Motor de audio nativo
FletAudio = None
try:
    import flet_audio as fa
    FletAudio = getattr(fa, "Audio", None)
except Exception:
    FletAudio = getattr(ft, "Audio", None)

# Motor de video nativo
FletVideo = None
FletVideoMedia = None
try:
    import flet_video as fv
    FletVideo = getattr(fv, "Video", None)
    FletVideoMedia = getattr(fv, "VideoMedia", None)
except Exception:
    FletVideo = getattr(ft, "Video", None)
    FletVideoMedia = getattr(ft, "VideoMedia", None)

# Permisos de Android (para el APK)
PermHandler = None
PermType = None
try:
    import flet_permission_handler as fph
    PermHandler = getattr(fph, "PermissionHandler", None)
    PermType = getattr(fph, "PermissionType", None) or getattr(fph, "Permission", None)
except Exception:
    PermHandler = None
    PermType = None

# Lector de portadas y metadatos bajo demanda
MUTAGEN_OK = False
try:
    from mutagen import File as MutagenFile
    MUTAGEN_OK = True
except Exception:
    MUTAGEN_OK = False


AUDIO_EXTS = {
    ".mp3", ".wav", ".ogg", ".flac", ".m4a", ".aac",
    ".opus", ".wma", ".amr", ".oga", ".aiff",
}
VIDEO_EXTS = {
    ".mp4", ".mkv", ".webm", ".mov", ".avi", ".m4v",
    ".3gp", ".ts", ".flv", ".mpeg", ".mpg",
}
ALL_MEDIA_EXTS = AUDIO_EXTS | VIDEO_EXTS

ACCENT_THEMES = {
    "Morado": "#9B5DE5",
    "Verde": "#1DB954",
    "Naranja": "#FF6B35",
    "Azul": "#00BBF9",
    "Rosa": "#F15BB5",
}

SPEED_OPTIONS = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
SORT_OPTIONS = [
    ("recientes", "Recientes"),
    ("az", "A-Z"),
    ("carpeta", "Origen"),
]
DIAS_SEMANA = ["Lun", "Mar", "Mié", "Jue", "Vie", "Sáb", "Dom"]
ITEMS_POR_PAGINA = 35

APP_FONTS = {
    "Poppins": "https://raw.githubusercontent.com/google/fonts/main/ofl/poppins/Poppins-Regular.ttf",
    "PoppinsSemi": "https://raw.githubusercontent.com/google/fonts/main/ofl/poppins/Poppins-SemiBold.ttf",
}

ANDROID_ROOT = "/storage/emulated/0"
IGNORED_DIR_NAMES = {
    ".thumbnails", ".trash", ".cache", "cache", "temp", "tmp",
    "notifications", "ringtones", "alarms", "stickers", "obb", "data",
    "appdata", "node_modules", ".git", "__pycache__", "venv", ".venv",
}


def es_entorno_android() -> bool:
    return (
        os.path.isdir(ANDROID_ROOT)
        or "ANDROID_ROOT" in os.environ
        or "ANDROID_DATA" in os.environ
    )


def es_uri_android(ruta: str) -> bool:
    return isinstance(ruta, str) and ruta.startswith("content://")


def hex_con_opacidad(hex_color: str, alpha_hex: str) -> str:
    clean = hex_color.lstrip("#")
    return f"#{alpha_hex}{clean}"


def mezclar_color_solido(hex_acento: str, hex_fondo: str, peso_acento: float = 0.28) -> str:
    """Mezcla dos colores y devuelve un hex 100% opaco (sin transparencia) para el fondo del reproductor."""
    c1 = hex_acento.lstrip("#")
    c2 = hex_fondo.lstrip("#")
    r1, g1, b1 = int(c1[0:2], 16), int(c1[2:4], 16), int(c1[4:6], 16)
    r2, g2, b2 = int(c2[0:2], 16), int(c2[2:4], 16), int(c2[4:6], 16)
    p = max(0.0, min(1.0, peso_acento))
    r = int(round(r1 * p + r2 * (1.0 - p)))
    g = int(round(g1 * p + g2 * (1.0 - p)))
    b = int(round(b1 * p + b2 * (1.0 - p)))
    return f"#{r:02X}{g:02X}{b:02X}"


def formatear_tiempo(segundos: float) -> str:
    segundos = max(0, int(segundos))
    mins, secs = divmod(segundos, 60)
    hrs, mins = divmod(mins, 60)
    if hrs > 0:
        return f"{hrs}:{mins:02d}:{secs:02d}"
    return f"{mins}:{secs:02d}"


def obtener_parametros_clase(cls) -> set:
    """Detecta los argumentos validos de una clase de Flet (compatible con 0.x y 1.x)."""
    nombres = set()
    if cls is None:
        return nombres
    try:
        if dataclasses.is_dataclass(cls):
            for f in dataclasses.fields(cls):
                nombres.add(f.name)
    except Exception:
        pass
    try:
        sig = inspect.signature(cls.__init__)
        for k, param in sig.parameters.items():
            if k != "self" and param.kind not in (
                inspect.Parameter.VAR_POSITIONAL,
                inspect.Parameter.VAR_KEYWORD,
            ):
                nombres.add(k)
    except Exception:
        pass
    return nombres


def extraer_segundos_evento(val) -> float:
    """Convierte Duration, timedelta, int/float (ms) o string a segundos reales."""
    if val is None:
        return -1.0
    try:
        if hasattr(val, "in_milliseconds"):
            return float(val.in_milliseconds) / 1000.0
        if hasattr(val, "total_seconds"):
            return float(val.total_seconds())
        if isinstance(val, (int, float)):
            return float(val) / 1000.0
        s = str(val).strip()
        if s:
            return float(s) / 1000.0
    except Exception:
        pass
    return -1.0


def cargar_logo_local_b64() -> str:
    for carpeta in (BASE_DIR, os.path.join(BASE_DIR, "assets")):
        for nombre in ("logo.png", "logo.jpg", "logo.jpeg", "logo.webp"):
            ruta = os.path.join(carpeta, nombre)
            if os.path.isfile(ruta):
                try:
                    with open(ruta, "rb") as f:
                        return base64.b64encode(f.read()).decode("utf-8")
                except Exception:
                    pass
    return ""


# --- Helpers seguros para Flet 1.x ---
def borde_todos(ancho: float, color: str):
    lado = ft.BorderSide(ancho, color)
    return ft.Border(left=lado, right=lado, top=lado, bottom=lado)


def borde_superior(ancho: float, color: str):
    return ft.Border(top=ft.BorderSide(ancho, color))


def crear_animacion(ms: int, curva_nombre: str = "EASE_OUT_CUBIC"):
    AnimCls = getattr(ft, "Animation", None)
    CurveEnum = getattr(ft, "AnimationCurve", None)
    if AnimCls is None and hasattr(ft, "animation"):
        AnimCls = getattr(ft.animation, "Animation", None)
        CurveEnum = CurveEnum or getattr(ft.animation, "AnimationCurve", None)
    if AnimCls is not None:
        curva = None
        if CurveEnum is not None:
            for cand in (curva_nombre, "DECELERATE", "EASE_OUT"):
                curva = getattr(CurveEnum, cand, None)
                if curva is not None:
                    break
        try:
            return AnimCls(ms, curva) if curva is not None else AnimCls(ms)
        except Exception:
            try:
                return AnimCls(duration=ms)
            except Exception:
                pass
    return ms


def crear_offset(x: float, y: float):
    OffCls = getattr(ft, "Offset", None)
    if OffCls is None and hasattr(ft, "transform"):
        OffCls = getattr(ft.transform, "Offset", None)
    return OffCls(x, y) if OffCls is not None else (x, y)


def crear_contenedor_animado(**kwargs):
    try:
        return ft.Container(**kwargs)
    except TypeError:
        for opt in ("animate_offset", "animate_opacity", "animate_scale", "animate"):
            if opt in kwargs:
                copia = dict(kwargs)
                copia.pop(opt, None)
                try:
                    return ft.Container(**copia)
                except TypeError:
                    kwargs = copia
        return ft.Container(**kwargs)


def crear_imagen_b64(b64_str: str, ancho: float, alto: float, radio: float, fit=FIT_COVER):
    try:
        return ft.Image(src_base64=b64_str, width=ancho, height=alto, fit=fit, border_radius=radio)
    except TypeError:
        try:
            return ft.Image(src=base64.b64decode(b64_str), width=ancho, height=alto, fit=fit, border_radius=radio)
        except Exception:
            return ft.Image(src=f"data:image/png;base64,{b64_str}", width=ancho, height=alto, fit=fit, border_radius=radio)


def crear_boton(etiqueta: str, on_click, bgcolor: str, color: str = "#FFFFFF", icono=None):
    BtnCls = getattr(ft, "Button", None) or getattr(ft, "ElevatedButton", ft.TextButton)
    contenido = (
        ft.Row(
            tight=True,
            spacing=5,
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
            controls=[
                ft.Icon(icono, size=16, color=color),
                ft.Text(etiqueta, color=color, font_family="PoppinsSemi", size=12),
            ],
        )
        if icono is not None
        else ft.Text(etiqueta, color=color, font_family="PoppinsSemi", size=12)
    )
    try:
        return BtnCls(content=contenido, bgcolor=bgcolor, color=color, on_click=on_click)
    except TypeError:
        return BtnCls(content=contenido, style=ft.ButtonStyle(bgcolor=bgcolor, color=color), on_click=on_click)


def crear_boton_texto(etiqueta: str, on_click, color=None):
    return ft.TextButton(
        content=ft.Text(etiqueta, color=color, font_family="PoppinsSemi", size=12),
        on_click=on_click,
    )


def crear_switch(valor: bool, color_acento: str, on_change):
    try:
        return ft.Switch(value=valor, active_color=color_acento, on_change=on_change)
    except TypeError:
        try:
            return ft.Switch(value=valor, active_track_color=color_acento, on_change=on_change)
        except TypeError:
            return ft.Switch(value=valor, on_change=on_change)


def envolver_safe_area(control):
    SafeAreaCls = getattr(ft, "SafeArea", None)
    if SafeAreaCls is not None:
        try:
            return SafeAreaCls(expand=True, content=control)
        except Exception:
            pass
    return control


# --- Escaneo ultrarrapido ---
_COVER_CACHE = {}


def crear_info_instantanea(ruta: str, nombre_opcional: str = "", mtime: float = None, forzar_es_video=None) -> dict:
    nombre_archivo = nombre_opcional or os.path.basename(ruta)
    nombre_base = os.path.splitext(nombre_archivo)[0] or "Sin título"
    carpeta = "Dispositivo" if es_uri_android(ruta) else (os.path.basename(os.path.dirname(ruta)) or "Dispositivo")

    ext = os.path.splitext(ruta)[1].lower() or os.path.splitext(nombre_opcional)[1].lower()
    if ext in VIDEO_EXTS:
        es_video = True
    elif ext in AUDIO_EXTS:
        es_video = False
    elif forzar_es_video is not None:
        es_video = bool(forzar_es_video)
    else:
        es_video = False

    if mtime is None:
        try:
            mtime = float(os.path.getmtime(ruta)) if not es_uri_android(ruta) else time.time()
        except Exception:
            mtime = time.time()

    return {
        "path": ruta,
        "title": nombre_base,
        "artist": carpeta,
        "folder": carpeta,
        "ext": (ext.upper().lstrip(".") or ("VIDEO" if es_video else "AUDIO")),
        "is_video": es_video,
        "duration": 0.0,
        "mtime": mtime,
    }


def leer_detalles_pista_actual(track: dict) -> tuple:
    """Lee portada, artista y duracion SOLO de la pista actual."""
    ruta = track["path"]
    if track["is_video"] or es_uri_android(ruta) or not MUTAGEN_OK or not os.path.isfile(ruta):
        return "", track["title"], track["artist"], track["duration"]

    cover_b64 = _COVER_CACHE.get(ruta, "")
    titulo = track["title"]
    artista = track["artist"]
    duracion = track["duration"]

    try:
        audio = MutagenFile(ruta)
        if audio is not None:
            if hasattr(audio, "info") and getattr(audio.info, "length", None):
                duracion = float(audio.info.length)
                track["duration"] = duracion
            tags = getattr(audio, "tags", None)
            if tags:
                for k in ("TIT2", "title", "\xa9nam"):
                    if k in tags:
                        val = tags[k]
                        titulo = str(val.text[0] if hasattr(val, "text") else val[0])
                        track["title"] = titulo
                        break
                for k in ("TPE1", "artist", "\xa9ART"):
                    if k in tags:
                        val = tags[k]
                        artista = str(val.text[0] if hasattr(val, "text") else val[0])
                        track["artist"] = artista
                        break
                if not cover_b64:
                    for key in list(tags.keys()):
                        if str(key).startswith("APIC"):
                            cover_b64 = base64.b64encode(tags[key].data).decode("utf-8")
                            break
                    if not cover_b64 and "covr" in tags:
                        cover_b64 = base64.b64encode(bytes(tags["covr"][0])).decode("utf-8")
                    if not cover_b64 and hasattr(audio, "pictures") and audio.pictures:
                        cover_b64 = base64.b64encode(audio.pictures[0].data).decode("utf-8")
                    if cover_b64:
                        if len(_COVER_CACHE) > 15:
                            _COVER_CACHE.clear()
                        _COVER_CACHE[ruta] = cover_b64
    except Exception:
        pass

    return cover_b64, titulo, artista, duracion


def obtener_raices_escaneo_automatico() -> list:
    raices = []
    if es_entorno_android():
        directas = [
            "/storage/emulated/0/Music",
            "/storage/emulated/0/Download",
            "/storage/emulated/0/Movies",
            "/storage/emulated/0/DCIM",
            "/storage/emulated/0/Snaptube",
            "/storage/emulated/0/Audio",
            "/storage/emulated/0/Podcasts",
            "/storage/emulated/0/Recordings",
            "/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Audio",
            "/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video",
            ANDROID_ROOT,
        ]
        for c in directas:
            if os.path.isdir(c) and c not in raices:
                raices.append(c)
        try:
            if os.path.isdir("/storage"):
                for entry in os.listdir("/storage"):
                    if entry not in ("emulated", "self"):
                        sd = os.path.join("/storage", entry)
                        if os.path.isdir(sd) and sd not in raices:
                            raices.append(sd)
        except Exception:
            pass
    else:
        home = os.path.expanduser("~")
        candidatos = [
            os.path.join(home, "Music"),
            os.path.join(home, "Música"),
            os.path.join(home, "Downloads"),
            os.path.join(home, "Descargas"),
            os.path.join(home, "Videos"),
            os.path.join(home, "Vídeos"),
            os.path.join(home, "Desktop"),
            os.path.join(home, "Escritorio"),
            os.path.join(home, "Documents"),
            os.path.join(home, "Documentos"),
            BASE_DIR,
        ]
        vistos = set()
        for c in candidatos:
            if os.path.isdir(c):
                norm = os.path.normcase(os.path.abspath(c))
                if norm not in vistos:
                    vistos.add(norm)
                    raices.append(c)
    return raices


def escanear_todo_el_dispositivo(manual_items: list) -> list:
    encontrados = []
    vistos = set()

    for raiz in obtener_raices_escaneo_automatico():
        try:
            for root, dirs, files in os.walk(raiz):
                dirs[:] = [
                    d for d in dirs
                    if not d.startswith(".") and d.lower() not in IGNORED_DIR_NAMES
                ]
                for fname in files:
                    if fname.startswith("."):
                        continue
                    ext = os.path.splitext(fname)[1].lower()
                    if ext in ALL_MEDIA_EXTS:
                        full = os.path.join(root, fname)
                        norm = os.path.normcase(full)
                        if norm not in vistos:
                            vistos.add(norm)
                            try:
                                mt = os.path.getmtime(full)
                            except Exception:
                                mt = 0.0
                            encontrados.append(crear_info_instantanea(full, mtime=mt))
        except PermissionError:
            pass

    for item in manual_items or []:
        ruta = item.get("path", "")
        if not ruta:
            continue
        norm = os.path.normcase(ruta)
        if norm in vistos:
            continue
        if es_uri_android(ruta) or os.path.isfile(ruta):
            vistos.add(norm)
            encontrados.append(
                crear_info_instantanea(
                    ruta,
                    nombre_opcional=item.get("name", ""),
                    forzar_es_video=item.get("is_video"),
                )
            )

    return encontrados


def cargar_datos() -> dict:
    base = {
        "manual_items": [],
        "dark_mode": True,
        "accent": "Morado",
        "pin": "1234",
        "private_paths": [],
        "favorites": [],
        "playlists": {},
        "stats": {
            "plays": 0,
            "daily_seconds": {d: 0 for d in DIAS_SEMANA},
        },
        "volume": 0.85,
    }
    if os.path.exists(DATA_FILE):
        try:
            with open(DATA_FILE, "r", encoding="utf-8") as f:
                saved = json.load(f)
            base.update(saved)
        except Exception:
            pass
    base["manual_items"] = [
        it for it in base.get("manual_items", [])
        if isinstance(it, dict) and it.get("path") and (es_uri_android(it["path"]) or os.path.isfile(it["path"]))
    ]
    return base


def guardar_datos(datos: dict):
    try:
        with open(DATA_FILE, "w", encoding="utf-8") as f:
            json.dump(datos, f, ensure_ascii=False, indent=2)
    except Exception:
        pass


def main(page: ft.Page):
    datos = cargar_datos()
    logo_b64 = cargar_logo_local_b64()
    en_android = es_entorno_android()
    audio_params = obtener_parametros_clase(FletAudio)

    page.title = "relaxPlayer"
    page.padding = 0
    page.spacing = 0
    page.fonts = APP_FONTS
    try:
        page.theme = ft.Theme(font_family="Poppins")
        page.dark_theme = ft.Theme(font_family="Poppins")
    except Exception:
        pass

    if not en_android:
        try:
            page.window.width = 400
            page.window.height = 800
        except Exception:
            pass

    estado = {
        "tracks": [],
        "music_filter": "Todas",
        "video_filter": "Todas",
        "music_search": "",
        "video_search": "",
        "music_sort": "recientes",
        "video_sort": "recientes",
        "music_limit": ITEMS_POR_PAGINA,
        "video_limit": ITEMS_POR_PAGINA,
        "private_filter": "audio",
        "current_track": None,
        "current_cover_b64": "",
        "current_from_private": False,
        "active_playlist": None,
        "player_open": False,
        "anim_token": 0,
        "audio_token": 0,
        "audio_started": False,
        "is_playing": False,
        "seeking": False,
        "position": 0.0,
        "duration": 0.0,
        "shuffle": False,
        "repeat": False,
        "volume": float(datos.get("volume", 0.85)),
        "last_vol_push": 0.0,
        "speed": 1.0,
        "sleep_remaining": 0,
        "active_tab": 0,         # 0: Musica, 1: Videos, 2: Privado, 3: Ajustes
        "vault_unlocked": False,
        "running": True,
        "status_until": 0.0,
        "scanning": False,
        "last_pos_ui": 0.0,
        "search_token": 0,
        "last_audio_error": "",
    }

    def ancho_pantalla() -> float:
        try:
            w = page.width or getattr(getattr(page, "window", None), "width", None) or 390
            return float(w)
        except Exception:
            return 390.0

    def alto_pantalla() -> float:
        try:
            h = page.height or getattr(getattr(page, "window", None), "height", None) or 780
            return float(h)
        except Exception:
            return 780.0

    def paleta():
        dark = datos.get("dark_mode", True)
        accent = ACCENT_THEMES.get(datos.get("accent", "Morado"), "#9B5DE5")
        if dark:
            return {
                "bg": "#0B0B0F",
                "surface": "#15151C",
                "surface_alt": "#1E1E28",
                "text": "#F6F6F9",
                "subtext": "#9E9EAA",
                "accent": accent,
                "border": "#282836",
            }
        return {
            "bg": "#F4F4F8",
            "surface": "#FFFFFF",
            "surface_alt": "#EAEAF0",
            "text": "#111118",
            "subtext": "#5D5D6B",
            "accent": accent,
            "border": "#DCDCE6",
        }

    def actualizar_control(ctrl):
        try:
            ctrl.update()
        except Exception:
            pass

    # --- Banner liviano ---
    banner_texto = ft.Text("", size=12, color="#FFFFFF", font_family="PoppinsSemi")
    banner_aviso = ft.Container(
        visible=False,
        padding=ft.Padding(14, 8, 14, 8),
        border_radius=12,
        bgcolor="#272733",
        content=banner_texto,
    )

    def avisar(texto: str):
        estado["status_until"] = time.time() + 3.2
        p = paleta()
        banner_aviso.bgcolor = p["surface_alt"]
        banner_texto.color = p["text"]
        banner_texto.value = texto
        banner_aviso.visible = True
        actualizar_control(banner_aviso)

    def ejecutar_async(coro_fn, *args):
        if hasattr(page, "run_task"):
            page.run_task(coro_fn, *args)
        else:
            def _r():
                loop = asyncio.new_event_loop()
                try:
                    loop.run_until_complete(coro_fn(*args))
                finally:
                    loop.close()
            threading.Thread(target=_r, daemon=True).start()

    async def llamar_seguro(obj, nombre_metodo: str, *args, **kwargs):
        if obj is None:
            return None
        fn = getattr(obj, nombre_metodo, None)
        if fn is None:
            return None
        try:
            res = fn(*args, **kwargs)
            if inspect.isawaitable(res):
                return await res
            return res
        except Exception as ex:
            print(f"[relaxPlayer] Error llamando {nombre_metodo}:", ex)
            return None

    def registrar_servicio(servicio):
        if hasattr(page, "services"):
            if servicio not in page.services:
                page.services.append(servicio)
        elif hasattr(page, "overlay"):
            if servicio not in page.overlay:
                page.overlay.append(servicio)

    # Permisos Android (APK)
    perm_handler = None
    if en_android and PermHandler is not None:
        try:
            perm_handler = PermHandler()
            registrar_servicio(perm_handler)
        except Exception:
            perm_handler = None

    async def pedir_permisos_android():
        if perm_handler is None or PermType is None:
            return
        for nombre_perm in ("MANAGE_EXTERNAL_STORAGE", "AUDIO", "VIDEOS", "STORAGE"):
            perm = getattr(PermType, nombre_perm, None)
            if perm is not None:
                if hasattr(perm_handler, "request"):
                    await llamar_seguro(perm_handler, "request", perm)
                else:
                    await llamar_seguro(perm_handler, "request_permission", perm)

    # --- Escaneo automatico ---
    async def escanear_async(mostrar_aviso: bool = True):
        if estado["scanning"]:
            return
        estado["scanning"] = True
        if mostrar_aviso:
            avisar("Actualizando tu música y videos...")
        if en_android:
            await pedir_permisos_android()

        tracks_nuevos = await asyncio.to_thread(escanear_todo_el_dispositivo, list(datos.get("manual_items", [])))
        estado["tracks"] = tracks_nuevos
        estado["scanning"] = False

        if estado["active_tab"] in (0, 1):
            refrescar_vista_base()
        if mostrar_aviso:
            n_m = len(obtener_lista(False, False))
            n_v = len(obtener_lista(True, False))
            avisar(f"Listo: {n_m} canciones y {n_v} videos encontrados.")

    def obtener_lista(es_video: bool, solo_privadas: bool = False):
        privadas = set(datos.get("private_paths", []))
        res = []
        for t in estado["tracks"]:
            if t["is_video"] != es_video:
                continue
            es_priv = t["path"] in privadas
            if solo_privadas and not es_priv:
                continue
            if not solo_privadas and es_priv:
                continue
            res.append(t)
        return res

    def ordenar_lista(lista: list, modo_orden: str) -> list:
        if modo_orden == "recientes":
            return sorted(lista, key=lambda x: x.get("mtime", 0.0), reverse=True)
        if modo_orden == "carpeta":
            return sorted(lista, key=lambda x: (x.get("folder", "").lower(), x.get("title", "").lower()))
        return sorted(lista, key=lambda x: x.get("title", "").lower())

    def obtener_tracks_playlist(nombre_pl: str):
        rutas = datos.get("playlists", {}).get(nombre_pl, [])
        mapa = {t["path"]: t for t in obtener_lista(es_video=False, solo_privadas=False)}
        return [mapa[r] for r in rutas if r in mapa]

    # --- Dialogos seguros ---
    def abrir_dialogo(dlg):
        if hasattr(page, "show_dialog"):
            page.show_dialog(dlg)
        elif hasattr(page, "open"):
            page.open(dlg)
        else:
            page.dialog = dlg
            dlg.open = True
            page.update()

    def cerrar_dialogo(dlg):
        if hasattr(page, "pop_dialog"):
            page.pop_dialog()
        elif hasattr(page, "close"):
            page.close(dlg)
        else:
            dlg.open = False
            page.update()

    # --- Motor de audio nativo compatible con Flet 1.x y 0.x ---
    audio_service = {"ctrl": None}
    video_widget_ref = {"ctrl": None}

    def _al_arrastrar_progreso(e):
        estado["seeking"] = True
        try:
            pos = float(e.control.value or 0.0)
            txt_tiempo_actual.value = formatear_tiempo(pos)
            actualizar_control(txt_tiempo_actual)
        except Exception:
            pass

    def _al_soltar_progreso(e):
        estado["seeking"] = False
        saltar_a_segundo(float(e.control.value or 0.0))

    slider_progreso = ft.Slider(
        min=0,
        max=100,
        value=0,
        on_change=_al_arrastrar_progreso,
        on_change_end=_al_soltar_progreso,
    )
    txt_tiempo_actual = ft.Text("0:00", size=11, font_family="PoppinsSemi")
    txt_tiempo_total = ft.Text("0:00", size=11, font_family="PoppinsSemi")
    contenedor_progreso = ft.Column(
        spacing=0,
        controls=[
            slider_progreso,
            ft.Row(alignment=ft.MainAxisAlignment.SPACE_BETWEEN, controls=[txt_tiempo_actual, txt_tiempo_total]),
        ],
    )

    # Controles persistentes de volumen en vivo (sin esperar a soltar la barra)
    txt_volumen_pct = ft.Text(f"{int(round(estado['volume'] * 100))}%", size=11, font_family="PoppinsSemi", width=36, text_align=ft.TextAlign.RIGHT)

    def _aplicar_volumen_en_motores(val: float, forzar: bool = False):
        ahora = time.time()
        if not forzar and (ahora - estado["last_vol_push"] < 0.035):
            return
        estado["last_vol_push"] = ahora

        ctrl = audio_service["ctrl"]
        if ctrl is not None:
            try:
                ctrl.volume = val
                ctrl.update()
            except Exception:
                try:
                    page.update()
                except Exception:
                    pass

        vw = video_widget_ref["ctrl"]
        if vw is not None:
            try:
                vw.volume = val * 100.0
                vw.update()
            except Exception:
                pass

    def cambiar_volumen_en_vivo(e):
        val = max(0.0, min(1.0, float(e.control.value)))
        estado["volume"] = val
        txt_volumen_pct.value = f"{int(round(val * 100))}%"
        actualizar_control(txt_volumen_pct)
        _aplicar_volumen_en_motores(val, forzar=False)

    def finalizar_volumen(e):
        val = max(0.0, min(1.0, float(e.control.value)))
        estado["volume"] = val
        txt_volumen_pct.value = f"{int(round(val * 100))}%"
        actualizar_control(txt_volumen_pct)
        _aplicar_volumen_en_motores(val, forzar=True)
        datos["volume"] = val
        threading.Thread(target=guardar_datos, args=(dict(datos),), daemon=True).start()

    slider_volumen = ft.Slider(
        min=0.0,
        max=1.0,
        value=estado["volume"],
        expand=True,
        on_change=cambiar_volumen_en_vivo,
        on_change_end=finalizar_volumen,
    )

    txt_timer_badge = ft.Text("", size=11, font_family="PoppinsSemi")
    row_timer_badge = ft.Row(
        visible=False,
        tight=True,
        spacing=3,
        vertical_alignment=ft.CrossAxisAlignment.CENTER,
        controls=[ft.Icon(Icons.BEDTIME_ROUNDED, size=14), txt_timer_badge],
    )

    def actualizar_solo_progreso():
        if estado["seeking"]:
            return
        try:
            dur = float(estado["duration"] or 0.0)
            pos = max(0.0, float(estado["position"] or 0.0))
            dur_s = dur if dur > 0 else max(pos + 10.0, 1.0)
            slider_progreso.max = dur_s
            slider_progreso.value = min(pos, dur_s)
            txt_tiempo_actual.value = formatear_tiempo(pos)
            txt_tiempo_total.value = formatear_tiempo(dur)
            if estado["player_open"]:
                contenedor_progreso.update()
        except Exception:
            pass

    def _on_audio_pos(e):
        val = getattr(e, "position", None)
        if val is None:
            val = getattr(e, "data", None)
        seg = extraer_segundos_evento(val)
        if seg >= 0.0:
            estado["position"] = seg
            if seg > 0.05:
                estado["audio_started"] = True
            ahora = time.time()
            if estado["player_open"] and not estado["seeking"] and (ahora - estado["last_pos_ui"] >= 0.45):
                estado["last_pos_ui"] = ahora
                actualizar_solo_progreso()

    def _on_audio_dur(e):
        val = getattr(e, "duration", None)
        if val is None:
            val = getattr(e, "data", None)
        seg = extraer_segundos_evento(val)
        if seg > 0.0:
            estado["duration"] = seg
            if estado["player_open"]:
                actualizar_solo_progreso()

    def _on_audio_state(e):
        st = str(getattr(e, "state", None) or getattr(e, "data", "")).lower()
        if "playing" in st:
            estado["audio_started"] = True
            estado["is_playing"] = True
        elif "completed" in st:
            siguiente_pista()

    def _on_audio_loaded(e):
        if estado["is_playing"] and not estado["audio_started"] and audio_service["ctrl"] is not None:
            ejecutar_async(llamar_seguro, audio_service["ctrl"], "play")

    def construir_control_audio(ruta: str):
        """Instancia flet_audio.Audio adaptandose automaticamente a Flet 1.x (on_*_change) y 0.x (on_*_changed)."""
        if FletAudio is None:
            return None

        kw = {"src": ruta}
        if not audio_params or "autoplay" in audio_params:
            kw["autoplay"] = True
        if not audio_params or "volume" in audio_params:
            kw["volume"] = estado["volume"]
        if not audio_params or "playback_rate" in audio_params:
            kw["playback_rate"] = estado["speed"]

        # Detectar nombre exacto de eventos en esta version instalada de flet-audio
        if "on_position_change" in audio_params:
            kw["on_position_change"] = _on_audio_pos
        elif "on_position_changed" in audio_params:
            kw["on_position_changed"] = _on_audio_pos

        if "on_duration_change" in audio_params:
            kw["on_duration_change"] = _on_audio_dur
        elif "on_duration_changed" in audio_params:
            kw["on_duration_changed"] = _on_audio_dur

        if "on_state_change" in audio_params:
            kw["on_state_change"] = _on_audio_state
        elif "on_state_changed" in audio_params:
            kw["on_state_changed"] = _on_audio_state

        if "on_loaded" in audio_params:
            kw["on_loaded"] = _on_audio_loaded

        try:
            return FletAudio(**kw)
        except TypeError:
            # Respaldo minimo garantizado sin argumentos opcionales
            return FletAudio(src=ruta, autoplay=True, volume=estado["volume"])

    async def _buscar_posicion_segura(ctrl, ms: int):
        ms_int = max(0, int(ms))
        dur_cls = getattr(ft, "Duration", None)
        if dur_cls is not None:
            try:
                res = ctrl.seek(dur_cls(milliseconds=ms_int))
                if inspect.isawaitable(res):
                    await res
                return
            except TypeError:
                pass
            except Exception as ex:
                print("[relaxPlayer] seek(Duration) fallo:", ex)
        await llamar_seguro(ctrl, "seek", ms_int)

    async def _reproducir_audio_async(track: dict, tok: int):
        if FletAudio is None:
            estado["last_audio_error"] = "flet-audio no disponible"
            avisar("Motor de audio no instalado (flet-audio).")
            estado["is_playing"] = False
            refrescar_reproductor_y_mini()
            return

        try:
            # Leer portada y metadatos de esta cancion en paralelo sin trabar la UI
            cover_b64, _, _, _ = await asyncio.to_thread(leer_detalles_pista_actual, track)
            if estado["audio_token"] != tok:
                return
            estado["current_cover_b64"] = cover_b64
            if track.get("duration", 0) > 0:
                estado["duration"] = track["duration"]

            # Limpiar servicio anterior
            if audio_service["ctrl"] is not None:
                viejo = audio_service["ctrl"]
                audio_service["ctrl"] = None
                await llamar_seguro(viejo, "pause")
                await llamar_seguro(viejo, "release")
                try:
                    if hasattr(page, "services") and viejo in page.services:
                        page.services.remove(viejo)
                    elif hasattr(page, "overlay") and viejo in page.overlay:
                        page.overlay.remove(viejo)
                except Exception:
                    pass

            estado["audio_started"] = False
            estado["last_audio_error"] = ""

            nuevo = construir_control_audio(track["path"])
            if nuevo is None:
                avisar("No se pudo crear el reproductor de audio.")
                return

            audio_service["ctrl"] = nuevo
            registrar_servicio(nuevo)
            refrescar_reproductor_y_mini()
            page.update()

            # Esperar a que Flutter monte el servicio y arrancar si autoplay no inicio solo
            await asyncio.sleep(0.22)
            if estado["audio_token"] != tok or audio_service["ctrl"] is not nuevo:
                return
            if estado["is_playing"] and not estado["audio_started"]:
                await llamar_seguro(nuevo, "play")
        except Exception as ex:
            estado["last_audio_error"] = str(ex)
            estado["is_playing"] = False
            print("[relaxPlayer] Error al reproducir audio:", ex)
            avisar(f"Error de audio: {str(ex)[:90]}")
            refrescar_reproductor_y_mini()

    def reproducir_pista(track: dict, abrir_pantalla: bool = True):
        privadas = set(datos.get("private_paths", []))
        estado["audio_token"] += 1
        tok = estado["audio_token"]
        estado["current_track"] = track
        estado["current_from_private"] = track["path"] in privadas
        estado["position"] = 0.0
        estado["duration"] = track.get("duration") or 0.0
        estado["seeking"] = False
        estado["audio_started"] = False
        estado["current_cover_b64"] = _COVER_CACHE.get(track["path"], "") if not track["is_video"] else ""

        datos["stats"]["plays"] = datos["stats"].get("plays", 0) + 1
        threading.Thread(target=guardar_datos, args=(dict(datos),), daemon=True).start()

        if track["is_video"]:
            if audio_service["ctrl"] is not None:
                ejecutar_async(llamar_seguro, audio_service["ctrl"], "pause")
            estado["is_playing"] = True
            if abrir_pantalla:
                abrir_reproductor_animado()
            else:
                refrescar_reproductor_y_mini()
            return

        estado["is_playing"] = True
        if abrir_pantalla and not estado["player_open"]:
            abrir_reproductor_animado()
        else:
            refrescar_reproductor_y_mini()
        ejecutar_async(_reproducir_audio_async, track, tok)

    def alternar_play_pausa(e=None):
        track = estado["current_track"]
        if track is None:
            es_vid = estado["active_tab"] == 1
            lista = obtener_lista(es_video=es_vid, solo_privadas=False)
            if lista:
                reproducir_pista(lista[0], abrir_pantalla=True)
            else:
                avisar("No encontré archivos todavía. Toca el botón de actualizar.")
            return

        if track["is_video"]:
            vw = video_widget_ref["ctrl"]
            if vw is not None:
                ejecutar_async(llamar_seguro, vw, "play_or_pause")
            estado["is_playing"] = not estado["is_playing"]
            refrescar_reproductor_y_mini()
            return

        ctrl = audio_service["ctrl"]
        if ctrl is None:
            reproducir_pista(track, abrir_pantalla=estado["player_open"])
            return

        if estado["is_playing"]:
            ejecutar_async(llamar_seguro, ctrl, "pause")
            estado["is_playing"] = False
        else:
            if estado["audio_started"] or estado["position"] > 0:
                ejecutar_async(llamar_seguro, ctrl, "resume")
            else:
                ejecutar_async(llamar_seguro, ctrl, "play")
            estado["is_playing"] = True
        refrescar_reproductor_y_mini()

    def saltar_a_segundo(segundo: float):
        track = estado["current_track"]
        if track is None or track["is_video"]:
            return
        dur_lim = estado["duration"] if estado["duration"] > 0 else max(segundo, 1.0)
        segundo = max(0.0, min(segundo, dur_lim))
        estado["position"] = segundo
        if audio_service["ctrl"] is not None:
            ejecutar_async(_buscar_posicion_segura, audio_service["ctrl"], int(segundo * 1000))
        actualizar_solo_progreso()

    def cola_actual_para_pista(track: dict):
        if not track["is_video"] and not estado["current_from_private"] and estado.get("active_playlist"):
            pl_tracks = obtener_tracks_playlist(estado["active_playlist"])
            if pl_tracks:
                return pl_tracks
        modo = estado["video_sort"] if track["is_video"] else estado["music_sort"]
        return ordenar_lista(obtener_lista(es_video=track["is_video"], solo_privadas=estado["current_from_private"]), modo)

    def siguiente_pista(e=None):
        track = estado["current_track"]
        if track is None:
            return
        lista = cola_actual_para_pista(track)
        if not lista:
            estado["is_playing"] = False
            refrescar_reproductor_y_mini()
            return
        if estado["repeat"]:
            reproducir_pista(track, abrir_pantalla=estado["player_open"])
            return
        if estado["shuffle"] and len(lista) > 1:
            candidatas = [t for t in lista if t["path"] != track["path"]]
            reproducir_pista(random.choice(candidatas), abrir_pantalla=estado["player_open"])
            return
        rutas = [t["path"] for t in lista]
        idx = (rutas.index(track["path"]) + 1) % len(lista) if track["path"] in rutas else 0
        reproducir_pista(lista[idx], abrir_pantalla=estado["player_open"])

    def anterior_pista(e=None):
        track = estado["current_track"]
        if track is None:
            return
        if estado["position"] > 4 and not track["is_video"]:
            saltar_a_segundo(0)
            return
        lista = cola_actual_para_pista(track)
        if not lista:
            return
        rutas = [t["path"] for t in lista]
        idx = (rutas.index(track["path"]) - 1) % len(lista) if track["path"] in rutas else 0
        reproducir_pista(lista[idx], abrir_pantalla=estado["player_open"])

    def cambiar_velocidad(nueva_vel: float):
        estado["speed"] = float(nueva_vel)
        if audio_service["ctrl"] is not None:
            try:
                audio_service["ctrl"].playback_rate = estado["speed"]
                audio_service["ctrl"].update()
            except Exception:
                pass
        avisar(f"Velocidad: {estado['speed']:g}x")
        refrescar_reproductor_y_mini()

    # --- Favoritos, Playlists y Temporizador ---
    def es_favorito(ruta: str) -> bool:
        return ruta in datos.get("favorites", [])

    def alternar_favorito(ruta: str):
        favs = datos.setdefault("favorites", [])
        if ruta in favs:
            favs.remove(ruta)
            avisar("Quitado de Favoritos.")
        else:
            favs.append(ruta)
            avisar("Guardado en Favoritos.")
        guardar_datos(datos)
        refrescar_lista_actual()
        if estado["player_open"]:
            refrescar_reproductor_y_mini()

    def abrir_crear_playlist(ruta_inicial: str = None):
        campo = ft.TextField(label="Nombre de la lista", hint_text="Ej: Noche, Chill, Gym", autofocus=True, dense=True)

        def crear(_):
            nombre = (campo.value or "").strip()
            if not nombre:
                avisar("Escribe un nombre primero.")
                return
            pls = datos.setdefault("playlists", {})
            pls.setdefault(nombre, [])
            if ruta_inicial and ruta_inicial not in pls[nombre]:
                pls[nombre].append(ruta_inicial)
            guardar_datos(datos)
            cerrar_dialogo(dlg)
            if not ruta_inicial:
                estado["music_filter"] = f"PL::{nombre}"
            avisar(f"Lista '{nombre}' creada.")
            refrescar_vista_base()

        dlg = ft.AlertDialog(
            title=ft.Text("Nueva lista", font_family="PoppinsSemi"),
            content=campo,
            actions=[
                crear_boton_texto("Cancelar", lambda _: cerrar_dialogo(dlg)),
                crear_boton("Crear", crear, paleta()["accent"]),
            ],
        )
        abrir_dialogo(dlg)

    def abrir_selector_playlist(ruta_cancion: str):
        p = paleta()
        pls = datos.setdefault("playlists", {})

        def alternar(n):
            arr = pls.setdefault(n, [])
            if ruta_cancion in arr:
                arr.remove(ruta_cancion)
                avisar(f"Quitada de '{n}'.")
            else:
                arr.append(ruta_cancion)
                avisar(f"Agregada a '{n}'.")
            guardar_datos(datos)
            cerrar_dialogo(dlg)
            refrescar_lista_actual()

        items = [
            ft.ListTile(
                leading=ft.Icon(
                    Icons.CHECK_CIRCLE_ROUNDED if ruta_cancion in pls[n] else Icons.QUEUE_MUSIC_ROUNDED,
                    color=p["accent"] if ruta_cancion in pls[n] else p["subtext"],
                ),
                title=ft.Text(n, color=p["text"], font_family="PoppinsSemi"),
                on_click=lambda _, nom=n: alternar(nom),
            )
            for n in sorted(pls.keys())
        ] or [ft.Text("Crea tu primera lista abajo.", size=12, color=p["subtext"])]

        dlg = ft.AlertDialog(
            title=ft.Text("Agregar a lista", font_family="PoppinsSemi"),
            content=ft.Column(tight=True, width=290, scroll=ft.ScrollMode.AUTO, height=190, controls=items),
            actions=[
                crear_boton_texto("Cerrar", lambda _: cerrar_dialogo(dlg)),
                crear_boton("Nueva", lambda _: (cerrar_dialogo(dlg), abrir_crear_playlist(ruta_cancion)), p["accent"], icono=Icons.ADD_ROUNDED),
            ],
        )
        abrir_dialogo(dlg)

    def abrir_selector_velocidad(e=None):
        p = paleta()
        ops = [
            ft.ListTile(
                title=ft.Text(
                    f"{s:g}x" + ("  (Normal)" if s == 1.0 else ""),
                    color=p["accent"] if abs(estado["speed"] - s) < 0.01 else p["text"],
                    font_family="PoppinsSemi" if abs(estado["speed"] - s) < 0.01 else "Poppins",
                ),
                on_click=lambda _, v=s: (cerrar_dialogo(dlg), cambiar_velocidad(v)),
            )
            for s in SPEED_OPTIONS
        ]
        dlg = ft.AlertDialog(
            title=ft.Text("Velocidad", font_family="PoppinsSemi"),
            content=ft.Column(tight=True, spacing=2, controls=ops),
            actions=[crear_boton_texto("Cerrar", lambda _: cerrar_dialogo(dlg))],
        )
        abrir_dialogo(dlg)

    def abrir_temporizador(e=None):
        def fijar(mins):
            estado["sleep_remaining"] = mins * 60
            cerrar_dialogo(dlg)
            if mins == 0:
                row_timer_badge.visible = False
                avisar("Temporizador apagado.")
            else:
                txt_timer_badge.value = formatear_tiempo(estado["sleep_remaining"])
                row_timer_badge.visible = True
                avisar(f"Se pausará en {mins} min.")
            refrescar_reproductor_y_mini()

        dlg = ft.AlertDialog(
            title=ft.Text("Temporizador para dormir", font_family="PoppinsSemi"),
            content=ft.Column(
                tight=True,
                spacing=4,
                controls=[
                    ft.ListTile(title=ft.Text("5 minutos"), on_click=lambda _: fijar(5)),
                    ft.ListTile(title=ft.Text("15 minutos"), on_click=lambda _: fijar(15)),
                    ft.ListTile(title=ft.Text("30 minutos"), on_click=lambda _: fijar(30)),
                    ft.ListTile(title=ft.Text("60 minutos"), on_click=lambda _: fijar(60)),
                    ft.ListTile(title=ft.Text("Desactivar"), on_click=lambda _: fijar(0)),
                ],
            ),
            actions=[crear_boton_texto("Cerrar", lambda _: cerrar_dialogo(dlg))],
        )
        abrir_dialogo(dlg)

    # --- Reloj ligero en segundo plano ---
    async def bucle_reloj():
        acum = 0.0
        while estado["running"]:
            await asyncio.sleep(1.0)
            if banner_aviso.visible and time.time() > estado["status_until"]:
                banner_aviso.visible = False
                actualizar_control(banner_aviso)

            if estado["is_playing"] and estado["current_track"]:
                acum += 1.0
                if acum >= 15.0:
                    dia = DIAS_SEMANA[datetime.datetime.now().weekday()]
                    datos["stats"]["daily_seconds"][dia] = datos["stats"]["daily_seconds"].get(dia, 0) + 15
                    threading.Thread(target=guardar_datos, args=(dict(datos),), daemon=True).start()
                    acum = 0.0

            if estado["sleep_remaining"] > 0:
                estado["sleep_remaining"] = max(0, estado["sleep_remaining"] - 1)
                if estado["sleep_remaining"] == 0:
                    row_timer_badge.visible = False
                    if estado["is_playing"]:
                        if audio_service["ctrl"] is not None:
                            await llamar_seguro(audio_service["ctrl"], "pause")
                        estado["is_playing"] = False
                        refrescar_reproductor_y_mini()
                elif estado["player_open"]:
                    txt_timer_badge.value = formatear_tiempo(estado["sleep_remaining"])
                    actualizar_control(row_timer_badge)

    # --- Logo relaxPlayer (soporta base64 local y assets/logo.png dentro del APK) ---
    def widget_logo(p: dict, tam: int = 38):
        fallback_ico = ft.Container(
            width=tam,
            height=tam,
            border_radius=tam // 2,
            bgcolor=hex_con_opacidad(p["accent"], "28"),
            alignment=ft.Alignment(0, 0),
            content=ft.Icon(Icons.HEADPHONES_ROUNDED, color=p["accent"], size=int(tam * 0.56)),
        )
        if logo_b64:
            return ft.Container(
                width=tam,
                height=tam,
                border_radius=tam // 2,
                bgcolor="#FFFFFF",
                padding=2,
                content=crear_imagen_b64(logo_b64, tam - 4, tam - 4, (tam - 4) // 2, fit=FIT_CONTAIN),
            )
        try:
            return ft.Container(
                width=tam,
                height=tam,
                border_radius=tam // 2,
                bgcolor="#FFFFFF",
                padding=2,
                content=ft.Image(
                    src="logo.png",
                    width=tam - 4,
                    height=tam - 4,
                    fit=FIT_CONTAIN,
                    border_radius=(tam - 4) // 2,
                    error_content=fallback_ico,
                ),
            )
        except Exception:
            return fallback_ico

    def envolver_ancho_movil(contenido):
        w = ancho_pantalla()
        if w > 540:
            return ft.Container(
                expand=True,
                alignment=ft.Alignment(0, -1),
                content=ft.Container(width=500, expand=True, content=contenido),
            )
        return ft.Container(expand=True, content=contenido)

    # --- Buscador con debounce ---
    async def _aplicar_busqueda_debounce(tok: int):
        await asyncio.sleep(0.25)
        if estado["search_token"] != tok:
            return
        refrescar_lista_actual()

    def _al_buscar_musica(e):
        estado["music_search"] = e.control.value or ""
        estado["music_limit"] = ITEMS_POR_PAGINA
        estado["search_token"] += 1
        ejecutar_async(_aplicar_busqueda_debounce, estado["search_token"])

    def _al_buscar_video(e):
        estado["video_search"] = e.control.value or ""
        estado["video_limit"] = ITEMS_POR_PAGINA
        estado["search_token"] += 1
        ejecutar_async(_aplicar_busqueda_debounce, estado["search_token"])

    campo_busq_musica = ft.TextField(
        hint_text="Buscar canción o artista...",
        prefix_icon=Icons.SEARCH_ROUNDED,
        border_radius=14,
        dense=True,
        on_change=_al_buscar_musica,
    )
    campo_busq_video = ft.TextField(
        hint_text="Buscar video...",
        prefix_icon=Icons.SEARCH_ROUNDED,
        border_radius=14,
        dense=True,
        on_change=_al_buscar_video,
    )

    listview_media = ft.ListView(expand=True, spacing=6)
    texto_conteo_lista = ft.Text("", size=11, font_family="PoppinsSemi")
    contenedor_mini_barra = ft.Container()

    # --- Mini barra ---
    def construir_mini_barra(p: dict):
        track = estado["current_track"]
        if track is None:
            return None

        mini = (
            crear_imagen_b64(estado["current_cover_b64"], 42, 42, 10)
            if estado.get("current_cover_b64")
            else ft.Container(
                width=42,
                height=42,
                border_radius=10,
                bgcolor=hex_con_opacidad(p["accent"], "28"),
                alignment=ft.Alignment(0, 0),
                content=ft.Icon(Icons.MOVIE_ROUNDED if track["is_video"] else Icons.MUSIC_NOTE_ROUNDED, color=p["accent"], size=21),
            )
        )

        return ft.Container(
            padding=ft.Padding(12, 6, 12, 6),
            bgcolor=p["bg"],
            content=ft.Container(
                bgcolor=p["surface_alt"],
                border_radius=16,
                padding=ft.Padding(10, 7, 6, 7),
                border=borde_todos(1, hex_con_opacidad(p["accent"], "44")),
                on_click=lambda _: abrir_reproductor_animado(),
                content=ft.Row(
                    vertical_alignment=ft.CrossAxisAlignment.CENTER,
                    spacing=10,
                    controls=[
                        mini,
                        ft.Column(
                            expand=True,
                            spacing=1,
                            controls=[
                                ft.Text(track["title"], size=13, font_family="PoppinsSemi", color=p["text"], max_lines=1, overflow=ft.TextOverflow.ELLIPSIS),
                                ft.Text("Video - Toca para ver" if track["is_video"] else track["artist"], size=11, color=p["subtext"], max_lines=1, overflow=ft.TextOverflow.ELLIPSIS),
                            ],
                        ),
                        ft.IconButton(
                            icon=Icons.PAUSE_ROUNDED if estado["is_playing"] else Icons.PLAY_ARROW_ROUNDED,
                            icon_color=p["text"],
                            icon_size=26,
                            on_click=alternar_play_pausa,
                        ),
                        ft.IconButton(
                            icon=Icons.SKIP_NEXT_ROUNDED,
                            icon_color=p["subtext"],
                            icon_size=24,
                            on_click=siguiente_pista,
                        ),
                    ],
                ),
            ),
        )

    def crear_pastilla_bajar(p: dict):
        zona = ft.Container(
            width=160,
            height=18,
            alignment=ft.Alignment(0, 0),
            on_click=lambda _: cerrar_reproductor_animado(),
            content=ft.Container(width=42, height=4, border_radius=2, bgcolor=hex_con_opacidad(p["text"], "35")),
        )
        try:
            def _drag(e):
                vel = getattr(e, "primary_velocity", None) or getattr(e, "velocity_y", 0) or 0
                if vel > 120:
                    cerrar_reproductor_animado()
            return ft.GestureDetector(content=zona, on_vertical_drag_end=_drag)
        except Exception:
            return zona

    # --- Vista Reproductor de MUSICA (100% opaco: cero transparencia hacia la lista) ---
    def vista_reproductor_musica(p: dict):
        track = estado["current_track"]
        titulo = track["title"] if track else "relaxPlayer"
        artista = track["artist"] if track else ""

        w = min(ancho_pantalla(), 480.0)
        h = alto_pantalla()
        cover_size = int(max(180, min(310, w * 0.72, h * 0.35)))

        fallback_portada = ft.Container(
            width=cover_size,
            height=cover_size,
            border_radius=22,
            bgcolor=p["surface_alt"],
            border=borde_todos(1, hex_con_opacidad(p["accent"], "44")),
            alignment=ft.Alignment(0, 0),
            content=ft.Icon(Icons.HEADPHONES_ROUNDED, size=int(cover_size * 0.36), color=p["accent"]),
        )

        if estado.get("current_cover_b64"):
            contenido_portada = crear_imagen_b64(estado["current_cover_b64"], cover_size, cover_size, 22)
        elif logo_b64:
            pad_logo = max(14, int(cover_size * 0.08))
            contenido_portada = ft.Container(
                width=cover_size,
                height=cover_size,
                border_radius=22,
                bgcolor="#FFFFFF",
                padding=pad_logo,
                alignment=ft.Alignment(0, 0),
                content=crear_imagen_b64(logo_b64, cover_size - pad_logo * 2, cover_size - pad_logo * 2, 16, fit=FIT_CONTAIN),
            )
        else:
            pad_logo = max(14, int(cover_size * 0.08))
            try:
                contenido_portada = ft.Container(
                    width=cover_size,
                    height=cover_size,
                    border_radius=22,
                    bgcolor="#FFFFFF",
                    padding=pad_logo,
                    alignment=ft.Alignment(0, 0),
                    content=ft.Image(
                        src="logo.png",
                        width=cover_size - pad_logo * 2,
                        height=cover_size - pad_logo * 2,
                        fit=FIT_CONTAIN,
                        border_radius=16,
                        error_content=fallback_portada,
                    ),
                )
            except Exception:
                contenido_portada = fallback_portada

        slider_progreso.active_color = p["accent"]
        slider_progreso.inactive_color = p["border"]
        slider_progreso.thumb_color = p["text"]
        txt_tiempo_actual.color = p["subtext"]
        txt_tiempo_total.color = p["subtext"]
        txt_timer_badge.color = p["accent"]
        row_timer_badge.controls[0].color = p["accent"]

        slider_volumen.active_color = p["accent"]
        slider_volumen.inactive_color = p["border"]
        slider_volumen.thumb_color = p["accent"]
        slider_volumen.value = estado["volume"]
        txt_volumen_pct.color = p["subtext"]
        txt_volumen_pct.value = f"{int(round(estado['volume'] * 100))}%"

        dur = float(estado["duration"] or 0.0)
        pos = max(0.0, float(estado["position"] or 0.0))
        dur_s = dur if dur > 0 else max(pos + 10.0, 1.0)
        slider_progreso.max = dur_s
        slider_progreso.value = min(pos, dur_s)
        txt_tiempo_actual.value = formatear_tiempo(pos)
        txt_tiempo_total.value = formatear_tiempo(dur)

        fav_activo = bool(track and es_favorito(track["path"]))
        color_arriba_solido = mezclar_color_solido(p["accent"], p["bg"], 0.28)

        cuerpo = ft.Column(
            expand=True,
            horizontal_alignment=ft.CrossAxisAlignment.CENTER,
            alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
            controls=[
                ft.Column(
                    horizontal_alignment=ft.CrossAxisAlignment.CENTER,
                    spacing=0,
                    controls=[
                        crear_pastilla_bajar(p),
                        ft.Row(
                            alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
                            vertical_alignment=ft.CrossAxisAlignment.CENTER,
                            controls=[
                                ft.IconButton(icon=Icons.KEYBOARD_ARROW_DOWN_ROUNDED, icon_size=28, icon_color=p["text"], on_click=lambda _: cerrar_reproductor_animado()),
                                ft.Column(
                                    horizontal_alignment=ft.CrossAxisAlignment.CENTER,
                                    spacing=0,
                                    controls=[
                                        ft.Text("REPRODUCIENDO", size=9, font_family="PoppinsSemi", color=p["subtext"]),
                                        ft.Text("relaxPlayer", size=13, font_family="PoppinsSemi", color=p["text"]),
                                    ],
                                ),
                                ft.Row(
                                    spacing=2,
                                    vertical_alignment=ft.CrossAxisAlignment.CENTER,
                                    controls=[
                                        row_timer_badge,
                                        ft.IconButton(icon=Icons.BEDTIME_OUTLINED, icon_size=22, icon_color=p["accent"] if estado["sleep_remaining"] > 0 else p["subtext"], on_click=abrir_temporizador),
                                    ],
                                ),
                            ],
                        ),
                    ],
                ),
                contenido_portada,
                ft.Row(
                    alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
                    vertical_alignment=ft.CrossAxisAlignment.CENTER,
                    controls=[
                        ft.Column(
                            expand=True,
                            spacing=1,
                            controls=[
                                ft.Text(titulo, size=18, font_family="PoppinsSemi", color=p["text"], max_lines=1, overflow=ft.TextOverflow.ELLIPSIS),
                                ft.Text(artista, size=13, color=p["subtext"], max_lines=1, overflow=ft.TextOverflow.ELLIPSIS),
                            ],
                        ),
                        ft.IconButton(icon=Icons.PLAYLIST_ADD_ROUNDED, icon_size=22, icon_color=p["subtext"], on_click=lambda _: abrir_selector_playlist(track["path"]) if track else None),
                        ft.IconButton(
                            icon=Icons.FAVORITE_ROUNDED if fav_activo else Icons.FAVORITE_BORDER_ROUNDED,
                            icon_size=23,
                            icon_color=p["accent"] if fav_activo else p["subtext"],
                            on_click=lambda _: alternar_favorito(track["path"]) if track else None,
                        ),
                    ],
                ),
                contenedor_progreso,
                ft.Row(
                    alignment=ft.MainAxisAlignment.SPACE_EVENLY,
                    vertical_alignment=ft.CrossAxisAlignment.CENTER,
                    controls=[
                        ft.IconButton(icon=Icons.SHUFFLE_ROUNDED, icon_size=22, icon_color=p["accent"] if estado["shuffle"] else p["subtext"], on_click=lambda _: (estado.update({"shuffle": not estado["shuffle"]}), refrescar_reproductor_y_mini())),
                        ft.IconButton(icon=Icons.SKIP_PREVIOUS_ROUNDED, icon_size=34, icon_color=p["text"], on_click=anterior_pista),
                        ft.Container(
                            width=62,
                            height=62,
                            border_radius=31,
                            bgcolor=p["accent"],
                            alignment=ft.Alignment(0, 0),
                            on_click=alternar_play_pausa,
                            content=ft.Icon(Icons.PAUSE_ROUNDED if estado["is_playing"] else Icons.PLAY_ARROW_ROUNDED, color="#FFFFFF", size=34),
                        ),
                        ft.IconButton(icon=Icons.SKIP_NEXT_ROUNDED, icon_size=34, icon_color=p["text"], on_click=siguiente_pista),
                        ft.IconButton(icon=Icons.REPEAT_ROUNDED, icon_size=22, icon_color=p["accent"] if estado["repeat"] else p["subtext"], on_click=lambda _: (estado.update({"repeat": not estado["repeat"]}), refrescar_reproductor_y_mini())),
                    ],
                ),
                ft.Row(
                    alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
                    vertical_alignment=ft.CrossAxisAlignment.CENTER,
                    spacing=6,
                    controls=[
                        ft.Container(
                            padding=ft.Padding(10, 6, 10, 6),
                            border_radius=14,
                            bgcolor=p["surface_alt"],
                            border=borde_todos(1, p["border"]),
                            on_click=abrir_selector_velocidad,
                            content=ft.Row(
                                tight=True,
                                spacing=4,
                                controls=[
                                    ft.Icon(Icons.SPEED_ROUNDED, size=14, color=p["accent"]),
                                    ft.Text(f"{estado['speed']:g}x", size=11, font_family="PoppinsSemi", color=p["text"]),
                                ],
                            ),
                        ),
                        ft.Row(
                            expand=True,
                            spacing=2,
                            vertical_alignment=ft.CrossAxisAlignment.CENTER,
                            controls=[
                                ft.Icon(Icons.VOLUME_DOWN_ROUNDED, size=18, color=p["subtext"]),
                                slider_volumen,
                                txt_volumen_pct,
                            ],
                        ),
                    ],
                ),
            ],
        )

        return ft.Container(
            expand=True,
            bgcolor=p["bg"],
            padding=ft.Padding(18, 8, 18, 12),
            gradient=ft.LinearGradient(
                begin=ft.Alignment(0, -1),
                end=ft.Alignment(0, 0.72),
                colors=[color_arriba_solido, p["bg"]],
            ),
            content=envolver_ancho_movil(cuerpo),
        )

    # --- Vista Reproductor de VIDEO integrado ---
    def vista_reproductor_video(p: dict):
        track = estado["current_track"]
        titulo = track["title"] if track else "Video"

        if FletVideo is not None and FletVideoMedia is not None and track:
            try:
                vid_params = obtener_parametros_clase(FletVideo)
                v_kw = {
                    "expand": True,
                    "playlist": [FletVideoMedia(track["path"])],
                    "autoplay": True,
                    "volume": estado["volume"] * 100.0,
                    "show_controls": True,
                }
                if not vid_params or "fill_color" in vid_params:
                    v_kw["fill_color"] = "#000000"
                vid = FletVideo(**v_kw)
                video_widget_ref["ctrl"] = vid
                escenario = ft.Container(expand=True, border_radius=16, bgcolor="#000000", content=vid)
            except Exception as ex:
                video_widget_ref["ctrl"] = None
                escenario = ft.Container(
                    expand=True,
                    border_radius=16,
                    bgcolor="#000000",
                    alignment=ft.Alignment(0, 0),
                    padding=20,
                    content=ft.Text(f"No se pudo abrir el video aquí: {ex}", color=p["subtext"], text_align=ft.TextAlign.CENTER),
                )
        else:
            video_widget_ref["ctrl"] = None
            escenario = ft.Container(
                expand=True,
                border_radius=16,
                bgcolor="#000000",
                alignment=ft.Alignment(0, 0),
                padding=24,
                content=ft.Column(
                    alignment=ft.MainAxisAlignment.CENTER,
                    horizontal_alignment=ft.CrossAxisAlignment.CENTER,
                    spacing=10,
                    controls=[
                        ft.Icon(Icons.SMART_DISPLAY_ROUNDED, size=54, color=p["accent"]),
                        ft.Text("Activa el video integrado", size=16, font_family="PoppinsSemi", color=p["text"]),
                        ft.Text("Instala flet-video para reproducir videos aquí dentro.", size=12, color=p["subtext"], text_align=ft.TextAlign.CENTER),
                    ],
                ),
            )

        slider_volumen.active_color = p["accent"]
        slider_volumen.inactive_color = p["border"]
        slider_volumen.thumb_color = p["accent"]
        slider_volumen.value = estado["volume"]
        txt_volumen_pct.color = p["subtext"]
        txt_volumen_pct.value = f"{int(round(estado['volume'] * 100))}%"

        cuerpo = ft.Column(
            expand=True,
            spacing=10,
            controls=[
                ft.Row(
                    alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
                    vertical_alignment=ft.CrossAxisAlignment.CENTER,
                    controls=[
                        ft.IconButton(icon=Icons.ARROW_BACK_ROUNDED, icon_color=p["text"], on_click=lambda _: cerrar_reproductor_animado()),
                        ft.Text(titulo, expand=True, size=15, font_family="PoppinsSemi", color=p["text"], max_lines=1, overflow=ft.TextOverflow.ELLIPSIS),
                        ft.IconButton(
                            icon=Icons.FAVORITE_ROUNDED if (track and es_favorito(track["path"])) else Icons.FAVORITE_BORDER_ROUNDED,
                            icon_color=p["accent"] if (track and es_favorito(track["path"])) else p["subtext"],
                            on_click=lambda _: alternar_favorito(track["path"]) if track else None,
                        ),
                    ],
                ),
                escenario,
                ft.Row(
                    alignment=ft.MainAxisAlignment.SPACE_EVENLY,
                    controls=[
                        ft.IconButton(icon=Icons.SKIP_PREVIOUS_ROUNDED, icon_size=32, icon_color=p["text"], on_click=anterior_pista),
                        ft.Container(
                            width=56,
                            height=56,
                            border_radius=28,
                            bgcolor=p["accent"],
                            alignment=ft.Alignment(0, 0),
                            on_click=alternar_play_pausa,
                            content=ft.Icon(Icons.PAUSE_ROUNDED if estado["is_playing"] else Icons.PLAY_ARROW_ROUNDED, color="#FFFFFF", size=30),
                        ),
                        ft.IconButton(icon=Icons.SKIP_NEXT_ROUNDED, icon_size=32, icon_color=p["text"], on_click=siguiente_pista),
                    ],
                ),
                ft.Row(
                    vertical_alignment=ft.CrossAxisAlignment.CENTER,
                    spacing=4,
                    controls=[
                        ft.Icon(Icons.VOLUME_DOWN_ROUNDED, size=18, color=p["subtext"]),
                        slider_volumen,
                        txt_volumen_pct,
                    ],
                ),
            ],
        )

        return ft.Container(expand=True, bgcolor=p["bg"], padding=ft.Padding(14, 10, 14, 12), content=envolver_ancho_movil(cuerpo))

    # --- Llenado paginado y ultraligero ---
    def poblar_filas_media(p: dict, es_video: bool):
        clave_filtro = "video_filter" if es_video else "music_filter"
        clave_busq = "video_search" if es_video else "music_search"
        clave_orden = "video_sort" if es_video else "music_sort"
        clave_limite = "video_limit" if es_video else "music_limit"

        visibles = obtener_lista(es_video=es_video, solo_privadas=False)
        pl_actual = estado[clave_filtro][4:] if (not es_video and str(estado[clave_filtro]).startswith("PL::")) else None
        base = obtener_tracks_playlist(pl_actual) if pl_actual else visibles

        q = estado[clave_busq].lower().strip()
        filtradas = []
        for t in base:
            if not pl_actual:
                if estado[clave_filtro] == "Favoritos" and not es_favorito(t["path"]):
                    continue
                elif estado[clave_filtro] not in ("Todas", "Favoritos") and t["folder"] != estado[clave_filtro]:
                    continue
            if q and q not in t["title"].lower() and q not in t["artist"].lower():
                continue
            filtradas.append(t)

        filtradas = ordenar_lista(filtradas, estado[clave_orden])
        total_n = len(filtradas)
        texto_conteo_lista.value = f"{total_n} {'videos' if es_video else 'canciones'}"
        texto_conteo_lista.color = p["subtext"]

        def mover_priv(ruta):
            if ruta not in datos["private_paths"]:
                datos["private_paths"].append(ruta)
                guardar_datos(datos)
                avisar("Movido a Zona Privada.")
                refrescar_lista_actual()

        filas = []
        if not filtradas:
            filas.append(
                ft.Container(
                    padding=ft.Padding(18, 36, 18, 24),
                    alignment=ft.Alignment(0, 0),
                    content=ft.Column(
                        horizontal_alignment=ft.CrossAxisAlignment.CENTER,
                        spacing=10,
                        controls=[
                            widget_logo(p, 76),
                            ft.Text(
                                "Buscando archivos..." if estado["scanning"] else f"No encontré {'videos' if es_video else 'canciones'}",
                                size=15,
                                font_family="PoppinsSemi",
                                color=p["text"],
                            ),
                            ft.Text(
                                "relaxPlayer lee automáticamente tu Música, Descargas y Videos sin que tengas que conectar carpetas.",
                                size=12,
                                color=p["subtext"],
                                text_align=ft.TextAlign.CENTER,
                            ),
                            crear_boton(
                                "Volver a escanear",
                                lambda _: ejecutar_async(escanear_async, True),
                                p["accent"],
                                icono=Icons.REFRESH_ROUNDED,
                            ),
                        ],
                    ),
                )
            )
        else:
            limite = int(estado[clave_limite])
            visibles_pagina = filtradas[:limite]
            ruta_actual = estado["current_track"]["path"] if estado["current_track"] else None

            for t in visibles_pagina:
                sonando = ruta_actual == t["path"]
                sub = f"{t['folder']} / {t['ext']}"
                filas.append(
                    ft.Container(
                        bgcolor=p["surface"] if not sonando else hex_con_opacidad(p["accent"], "24"),
                        border_radius=12,
                        padding=ft.Padding(10, 7, 4, 7),
                        on_click=lambda _, tr=t, pl_n=pl_actual: (
                            estado.update({"active_playlist": pl_n if not es_video else None}),
                            reproducir_pista(tr, abrir_pantalla=True),
                        ),
                        content=ft.Row(
                            vertical_alignment=ft.CrossAxisAlignment.CENTER,
                            spacing=10,
                            controls=[
                                ft.Container(
                                    width=42,
                                    height=42,
                                    border_radius=10,
                                    bgcolor=hex_con_opacidad(p["accent"], "30") if sonando else p["surface_alt"],
                                    alignment=ft.Alignment(0, 0),
                                    content=ft.Icon(
                                        Icons.GRAPHIC_EQ_ROUNDED if sonando else (Icons.PLAY_CIRCLE_FILL_ROUNDED if es_video else Icons.MUSIC_NOTE_ROUNDED),
                                        size=20,
                                        color=p["accent"] if sonando else p["subtext"],
                                    ),
                                ),
                                ft.Column(
                                    expand=True,
                                    spacing=1,
                                    controls=[
                                        ft.Text(t["title"], size=13, font_family="PoppinsSemi", color=p["accent"] if sonando else p["text"], max_lines=1, overflow=ft.TextOverflow.ELLIPSIS),
                                        ft.Text(sub, size=11, color=p["subtext"], max_lines=1, overflow=ft.TextOverflow.ELLIPSIS),
                                    ],
                                ),
                                ft.IconButton(
                                    icon=Icons.FAVORITE_ROUNDED if es_favorito(t["path"]) else Icons.FAVORITE_BORDER_ROUNDED,
                                    icon_size=18,
                                    icon_color=p["accent"] if es_favorito(t["path"]) else p["subtext"],
                                    on_click=lambda _, r=t["path"]: alternar_favorito(r),
                                ),
                                ft.IconButton(
                                    icon=Icons.LOCK_OUTLINE_ROUNDED,
                                    icon_size=18,
                                    icon_color=p["subtext"],
                                    on_click=lambda _, r=t["path"]: mover_priv(r),
                                ),
                            ],
                        ),
                    )
                )

            if total_n > limite:
                restantes = total_n - limite
                filas.append(
                    ft.Container(
                        padding=ft.Padding(0, 6, 0, 12),
                        alignment=ft.Alignment(0, 0),
                        content=crear_boton(
                            f"Ver más ({restantes} restantes)",
                            lambda _, k=clave_limite: (estado.update({k: estado[k] + ITEMS_POR_PAGINA}), refrescar_lista_actual()),
                            p["surface_alt"],
                            color=p["text"],
                        ),
                    )
                )

        listview_media.controls = filas

    def refrescar_lista_actual():
        if estado["active_tab"] in (0, 1):
            p = paleta()
            poblar_filas_media(p, es_video=(estado["active_tab"] == 1))
            actualizar_control(texto_conteo_lista)
            actualizar_control(listview_media)
        else:
            refrescar_vista_base()

    # --- Vista Lista (Musica / Videos) ---
    def vista_lista(p: dict, es_video: bool):
        titulo_sec = "Videos" if es_video else "Música"
        clave_filtro = "video_filter" if es_video else "music_filter"
        clave_orden = "video_sort" if es_video else "music_sort"
        clave_limite = "video_limit" if es_video else "music_limit"

        visibles = obtener_lista(es_video=es_video, solo_privadas=False)
        nombres_pl = sorted(datos.get("playlists", {}).keys()) if not es_video else []
        origenes = sorted({t["folder"] for t in visibles})[:8]
        filtros = ["Todas", "Favoritos"] + [f"PL::{n}" for n in nombres_pl] + origenes
        if estado[clave_filtro] not in filtros:
            estado[clave_filtro] = "Todas"

        chips = []
        for c in filtros:
            activo = c == estado[clave_filtro]
            fg = "#FFFFFF" if activo else p["text"]
            if c == "Favoritos":
                contenido_chip = ft.Row(
                    tight=True,
                    spacing=5,
                    controls=[
                        ft.Icon(Icons.FAVORITE_ROUNDED, size=13, color=fg if activo else p["accent"]),
                        ft.Text("Favoritos", size=12, font_family="PoppinsSemi", color=fg),
                    ],
                )
            elif c.startswith("PL::"):
                contenido_chip = ft.Row(
                    tight=True,
                    spacing=5,
                    controls=[
                        ft.Icon(Icons.QUEUE_MUSIC_ROUNDED, size=14, color=fg if activo else p["accent"]),
                        ft.Text(c[4:], size=12, font_family="PoppinsSemi", color=fg),
                    ],
                )
            else:
                contenido_chip = ft.Text(c, size=12, font_family="PoppinsSemi", color=fg)

            chips.append(
                ft.Container(
                    padding=ft.Padding(13, 6, 13, 6),
                    border_radius=18,
                    bgcolor=p["accent"] if activo else p["surface_alt"],
                    on_click=lambda _, nom=c, k=clave_filtro, kl=clave_limite: (estado.update({k: nom, kl: ITEMS_POR_PAGINA}), refrescar_vista_base()),
                    content=contenido_chip,
                )
            )
        if not es_video:
            chips.append(
                ft.Container(
                    padding=ft.Padding(11, 6, 11, 6),
                    border_radius=18,
                    bgcolor=p["surface"],
                    border=borde_todos(1, hex_con_opacidad(p["accent"], "66")),
                    on_click=lambda _: abrir_crear_playlist(),
                    content=ft.Row(
                        tight=True,
                        spacing=4,
                        controls=[
                            ft.Icon(Icons.ADD_ROUNDED, size=14, color=p["accent"]),
                            ft.Text("Lista", size=12, font_family="PoppinsSemi", color=p["accent"]),
                        ],
                    ),
                )
            )

        fila_orden = ft.Row(
            alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
            controls=[
                texto_conteo_lista,
                ft.Row(
                    spacing=6,
                    controls=[
                        ft.Container(
                            padding=ft.Padding(9, 4, 9, 4),
                            border_radius=10,
                            bgcolor=hex_con_opacidad(p["accent"], "28") if estado[clave_orden] == cod else "transparent",
                            on_click=lambda _, c_ord=cod, k=clave_orden, kl=clave_limite: (estado.update({k: c_ord, kl: ITEMS_POR_PAGINA}), refrescar_vista_base()),
                            content=ft.Text(
                                lbl,
                                size=11,
                                font_family="PoppinsSemi" if estado[clave_orden] == cod else "Poppins",
                                color=p["accent"] if estado[clave_orden] == cod else p["subtext"],
                            ),
                        )
                        for cod, lbl in SORT_OPTIONS
                    ],
                ),
            ],
        )

        campo_busq = campo_busq_video if es_video else campo_busq_musica
        campo_busq.bgcolor = p["surface"]
        campo_busq.border_color = p["border"]
        campo_busq.color = p["text"]

        poblar_filas_media(p, es_video=es_video)

        cuerpo = ft.Column(
            expand=True,
            spacing=10,
            controls=[
                ft.Row(
                    alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
                    vertical_alignment=ft.CrossAxisAlignment.CENTER,
                    controls=[
                        ft.Row(
                            spacing=10,
                            vertical_alignment=ft.CrossAxisAlignment.CENTER,
                            controls=[
                                widget_logo(p, 40),
                                ft.Column(
                                    spacing=0,
                                    controls=[
                                        ft.Text("relaxPlayer", size=11, font_family="PoppinsSemi", color=p["accent"]),
                                        ft.Text(titulo_sec, size=20, font_family="PoppinsSemi", color=p["text"]),
                                    ],
                                ),
                            ],
                        ),
                        ft.IconButton(
                            icon=Icons.REFRESH_ROUNDED,
                            icon_size=24,
                            icon_color=p["accent"],
                            tooltip="Actualizar biblioteca",
                            on_click=lambda _: ejecutar_async(escanear_async, True),
                        ),
                    ],
                ),
                banner_aviso,
                campo_busq,
                ft.Row(chips, scroll=ft.ScrollMode.AUTO, spacing=8),
                fila_orden,
                listview_media,
            ],
        )

        return ft.Container(expand=True, bgcolor=p["bg"], padding=ft.Padding(16, 12, 16, 4), content=envolver_ancho_movil(cuerpo))

    # --- Zona Privada ---
    def vista_privada(p: dict):
        if not estado["vault_unlocked"]:
            campo_pin = ft.TextField(label="PIN (inicial: 1234)", password=True, can_reveal_password=True, width=240, text_align=ft.TextAlign.CENTER, border_radius=14, bgcolor=p["surface"], color=p["text"])

            def verificar(_):
                if (campo_pin.value or "") == str(datos.get("pin", "1234")):
                    estado["vault_unlocked"] = True
                    refrescar_vista_base()
                else:
                    avisar("PIN incorrecto.")

            cuerpo = ft.Column(
                horizontal_alignment=ft.CrossAxisAlignment.CENTER,
                alignment=ft.MainAxisAlignment.CENTER,
                spacing=14,
                controls=[
                    banner_aviso,
                    ft.Container(width=72, height=72, border_radius=36, bgcolor=hex_con_opacidad(p["accent"], "24"), alignment=ft.Alignment(0, 0), content=ft.Icon(Icons.LOCK_ROUNDED, size=32, color=p["accent"])),
                    ft.Text("Zona Privada", size=21, font_family="PoppinsSemi", color=p["text"]),
                    campo_pin,
                    crear_boton("Desbloquear", verificar, p["accent"]),
                ],
            )
            return ft.Container(expand=True, bgcolor=p["bg"], alignment=ft.Alignment(0, 0), padding=24, content=envolver_ancho_movil(cuerpo))

        es_vid = estado["private_filter"] == "video"
        privadas = obtener_lista(es_video=es_vid, solo_privadas=True)

        def sacar(ruta):
            if ruta in datos["private_paths"]:
                datos["private_paths"].remove(ruta)
                guardar_datos(datos)
                avisar("Devuelto a tu biblioteca.")
                refrescar_vista_base()

        items = [
            ft.Container(
                bgcolor=p["surface"],
                border_radius=12,
                padding=ft.Padding(12, 8, 8, 8),
                on_click=lambda _, tr=t: reproducir_pista(tr, abrir_pantalla=True),
                content=ft.Row(
                    controls=[
                        ft.Icon(Icons.MOVIE_ROUNDED if es_vid else Icons.MUSIC_NOTE_ROUNDED, color=p["accent"]),
                        ft.Text(t["title"], expand=True, font_family="PoppinsSemi", color=p["text"], max_lines=1, overflow=ft.TextOverflow.ELLIPSIS),
                        ft.IconButton(icon=Icons.VISIBILITY_ROUNDED, icon_color=p["subtext"], on_click=lambda _, r=t["path"]: sacar(r)),
                    ]
                ),
            )
            for t in privadas
        ] or [ft.Text(f"No tienes {'videos' if es_vid else 'canciones'} ocultos.", size=13, color=p["subtext"])]

        cuerpo = ft.Column(
            expand=True,
            spacing=12,
            controls=[
                ft.Row(
                    alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
                    controls=[
                        ft.Text("Zona Privada", size=21, font_family="PoppinsSemi", color=p["text"]),
                        crear_boton_texto("Bloquear", lambda _: (estado.update({"vault_unlocked": False}), refrescar_vista_base()), p["accent"]),
                    ],
                ),
                ft.Row(
                    spacing=8,
                    controls=[
                        ft.Container(padding=ft.Padding(14, 7, 14, 7), border_radius=18, bgcolor=p["accent"] if not es_vid else p["surface_alt"], on_click=lambda _: (estado.update({"private_filter": "audio"}), refrescar_vista_base()), content=ft.Text("Música", size=12, font_family="PoppinsSemi", color="#FFFFFF" if not es_vid else p["text"])),
                        ft.Container(padding=ft.Padding(14, 7, 14, 7), border_radius=18, bgcolor=p["accent"] if es_vid else p["surface_alt"], on_click=lambda _: (estado.update({"private_filter": "video"}), refrescar_vista_base()), content=ft.Text("Videos", size=12, font_family="PoppinsSemi", color="#FFFFFF" if es_vid else p["text"])),
                    ],
                ),
                ft.ListView(expand=True, spacing=8, controls=items),
            ],
        )
        return ft.Container(expand=True, bgcolor=p["bg"], padding=ft.Padding(16, 12, 16, 6), content=envolver_ancho_movil(cuerpo))

    # --- Ajustes ---
    def vista_ajustes(p: dict):
        diarios = datos["stats"].get("daily_seconds", {})
        max_seg = max([60] + [diarios.get(d, 0) for d in DIAS_SEMANA])
        total_min = int(sum(diarios.values()) // 60)

        barras = [
            ft.Column(
                horizontal_alignment=ft.CrossAxisAlignment.CENTER,
                alignment=ft.MainAxisAlignment.END,
                spacing=4,
                controls=[
                    ft.Container(width=20, height=max(8, int((diarios.get(d, 0) / max_seg) * 76)), border_radius=7, bgcolor=p["accent"]),
                    ft.Text(d, size=10, font_family="PoppinsSemi", color=p["subtext"]),
                ],
            )
            for d in DIAS_SEMANA
        ]

        colores_ui = [
            ft.Container(
                width=34,
                height=34,
                border_radius=17,
                bgcolor=hx,
                border=borde_todos(3, p["text"]) if datos.get("accent") == nom else None,
                on_click=lambda _, n=nom: (datos.update({"accent": n}), guardar_datos(datos), refrescar_vista_base()),
            )
            for nom, hx in ACCENT_THEMES.items()
        ]

        nuevo_pin = ft.TextField(label="Cambiar PIN", max_length=6, dense=True, bgcolor=p["surface_alt"], color=p["text"], expand=True)

        def guardar_pin(_):
            val = (nuevo_pin.value or "").strip()
            if len(val) >= 4:
                datos["pin"] = val
                guardar_datos(datos)
                avisar("PIN actualizado.")
                nuevo_pin.value = ""
                actualizar_control(nuevo_pin)
            else:
                avisar("Usa mínimo 4 caracteres.")

        n_m = len(obtener_lista(False, False))
        n_v = len(obtener_lista(True, False))

        cuerpo = ft.ListView(
            expand=True,
            spacing=12,
            controls=[
                ft.Row(spacing=10, vertical_alignment=ft.CrossAxisAlignment.CENTER, controls=[widget_logo(p, 38), ft.Text("Ajustes relaxPlayer", size=20, font_family="PoppinsSemi", color=p["text"])]),
                banner_aviso,
                ft.Container(
                    bgcolor=p["surface"],
                    border_radius=18,
                    padding=14,
                    content=ft.Column(
                        spacing=10,
                        controls=[
                            ft.Row(alignment=ft.MainAxisAlignment.SPACE_BETWEEN, controls=[ft.Text("Tu semana", size=14, font_family="PoppinsSemi", color=p["text"]), ft.Text(f"{total_min} min / {datos['stats'].get('plays', 0)} reproducciones", size=11, font_family="PoppinsSemi", color=p["accent"])]),
                            ft.Container(height=98, alignment=ft.Alignment(0, 1), content=ft.Row(alignment=ft.MainAxisAlignment.SPACE_AROUND, vertical_alignment=ft.CrossAxisAlignment.END, controls=barras)),
                        ],
                    ),
                ),
                ft.Container(
                    bgcolor=p["surface"],
                    border_radius=18,
                    padding=14,
                    content=ft.Column(
                        spacing=10,
                        controls=[
                            ft.Row(alignment=ft.MainAxisAlignment.SPACE_BETWEEN, controls=[ft.Text("Modo oscuro", size=14, font_family="PoppinsSemi", color=p["text"]), crear_switch(datos.get("dark_mode", True), p["accent"], lambda e: (datos.update({"dark_mode": e.control.value}), guardar_datos(datos), refrescar_vista_base()))]),
                            ft.Text("Color principal", size=12, color=p["subtext"]),
                            ft.Row(spacing=12, controls=colores_ui),
                            ft.Text(f"Audio: {'Listo' if FletAudio else 'Falta flet-audio'} / Video: {'Listo' if FletVideo else 'Falta flet-video'}", size=11, color=p["subtext"]),
                            *(
                                [ft.Text(f"Último aviso audio: {estado['last_audio_error']}", size=10, color=p["accent"])]
                                if estado["last_audio_error"]
                                else []
                            ),
                        ],
                    ),
                ),
                ft.Container(
                    bgcolor=p["surface"],
                    border_radius=18,
                    padding=14,
                    content=ft.Row(controls=[nuevo_pin, crear_boton("Guardar", guardar_pin, p["accent"])]),
                ),
                ft.Container(
                    bgcolor=p["surface"],
                    border_radius=18,
                    padding=14,
                    content=ft.Row(
                        alignment=ft.MainAxisAlignment.SPACE_BETWEEN,
                        controls=[
                            ft.Column(
                                spacing=2,
                                controls=[
                                    ft.Text("Escaneo automático", size=14, font_family="PoppinsSemi", color=p["text"]),
                                    ft.Text(f"{n_m} canciones y {n_v} videos detectados", size=11, color=p["subtext"]),
                                ],
                            ),
                            crear_boton("Actualizar", lambda _: ejecutar_async(escanear_async, True), p["accent"], icono=Icons.REFRESH_ROUNDED),
                        ],
                    ),
                ),
            ],
        )

        return ft.Container(expand=True, bgcolor=p["bg"], padding=ft.Padding(16, 12, 16, 10), content=envolver_ancho_movil(cuerpo))

    # --- Navegacion inferior ---
    def barra_navegacion(p: dict):
        tabs = [
            (0, Icons.MUSIC_NOTE_ROUNDED, "Música"),
            (1, Icons.VIDEO_LIBRARY_ROUNDED, "Videos"),
            (2, Icons.LOCK_ROUNDED, "Privado"),
            (3, Icons.TUNE_ROUNDED, "Ajustes"),
        ]
        fila = ft.Row(
            controls=[
                ft.Container(
                    expand=True,
                    padding=ft.Padding(0, 7, 0, 7),
                    on_click=lambda _, i=idx: (estado.update({"active_tab": i}), cerrar_reproductor_animado() if estado["player_open"] else refrescar_vista_base()),
                    content=ft.Column(
                        horizontal_alignment=ft.CrossAxisAlignment.CENTER,
                        spacing=3,
                        tight=True,
                        controls=[
                            ft.Container(
                                padding=ft.Padding(14, 3, 14, 3),
                                border_radius=14,
                                bgcolor=hex_con_opacidad(p["accent"], "26") if estado["active_tab"] == idx else "transparent",
                                content=ft.Icon(ic, size=22, color=p["accent"] if estado["active_tab"] == idx else p["subtext"]),
                            ),
                            ft.Text(
                                lbl,
                                size=10,
                                font_family="PoppinsSemi" if estado["active_tab"] == idx else "Poppins",
                                color=p["accent"] if estado["active_tab"] == idx else p["subtext"],
                            ),
                        ],
                    ),
                )
                for idx, ic, lbl in tabs
            ]
        )
        return ft.Container(
            bgcolor=p["surface"],
            border=borde_superior(1, p["border"]),
            content=ft.Container(
                alignment=ft.Alignment(0, 0),
                content=ft.Container(width=min(ancho_pantalla(), 500), content=fila),
            ),
        )

    # --- Capas solidas: al subir el reproductor tapa 100% la lista y la oculta al terminar ---
    capa_lista = ft.Container(left=0, top=0, right=0, bottom=0, visible=True)

    capa_reproductor = crear_contenedor_animado(
        left=0, top=0, right=0, bottom=0,
        bgcolor="#0B0B0F",
        visible=False,
        offset=crear_offset(0, 1.0),
        animate_offset=crear_animacion(280, "EASE_OUT_CUBIC"),
    )

    page.add(envolver_safe_area(ft.Stack(expand=True, controls=[capa_lista, capa_reproductor])))

    def _montar_capa_lista(p: dict):
        if estado["active_tab"] == 0:
            cuerpo = vista_lista(p, es_video=False)
        elif estado["active_tab"] == 1:
            cuerpo = vista_lista(p, es_video=True)
        elif estado["active_tab"] == 2:
            cuerpo = vista_privada(p)
        else:
            cuerpo = vista_ajustes(p)

        contenedor_mini_barra.content = construir_mini_barra(p)
        capa_lista.bgcolor = p["bg"]
        capa_lista.content = ft.Column(
            expand=True,
            spacing=0,
            controls=[cuerpo, contenedor_mini_barra, barra_navegacion(p)],
        )

    def _montar_capa_reproductor(p: dict):
        if estado["current_track"] is None:
            return
        capa_reproductor.bgcolor = p["bg"]
        if estado["current_track"]["is_video"]:
            capa_reproductor.content = vista_reproductor_video(p)
        else:
            capa_reproductor.content = vista_reproductor_musica(p)

    def refrescar_vista_base(e=None):
        p = paleta()
        page.bgcolor = p["bg"]
        page.theme_mode = ft.ThemeMode.DARK if datos.get("dark_mode", True) else ft.ThemeMode.LIGHT
        _montar_capa_lista(p)
        if estado["player_open"] and estado["current_track"] is not None:
            _montar_capa_reproductor(p)
        page.update()

    def refrescar_reproductor_y_mini():
        p = paleta()
        contenedor_mini_barra.content = construir_mini_barra(p)
        actualizar_control(contenedor_mini_barra)
        if estado["player_open"] and estado["current_track"] is not None:
            _montar_capa_reproductor(p)
            actualizar_control(capa_reproductor)
        if estado["active_tab"] in (0, 1) and capa_lista.visible:
            poblar_filas_media(p, es_video=(estado["active_tab"] == 1))
            actualizar_control(listview_media)

    def abrir_reproductor_animado():
        if estado["current_track"] is None:
            return
        p = paleta()
        estado["anim_token"] += 1
        tok = estado["anim_token"]
        estado["player_open"] = True

        estaba = bool(capa_reproductor.visible)
        contenedor_mini_barra.content = construir_mini_barra(p)
        _montar_capa_reproductor(p)
        if not estaba:
            capa_reproductor.offset = crear_offset(0, 1.0)
            capa_reproductor.visible = True
            actualizar_control(capa_reproductor)

        async def _subir():
            if not estaba:
                await asyncio.sleep(0.02)
            if estado["anim_token"] != tok or not estado["player_open"]:
                return
            capa_reproductor.offset = crear_offset(0, 0.0)
            actualizar_control(capa_reproductor)
            # Al terminar de subir, ocultar por completo la capa de atras
            await asyncio.sleep(0.30)
            if estado["anim_token"] != tok or not estado["player_open"]:
                return
            capa_lista.visible = False
            actualizar_control(capa_lista)

        ejecutar_async(_subir)

    def cerrar_reproductor_animado():
        p = paleta()
        if estado["current_track"] and estado["current_track"]["is_video"] and video_widget_ref["ctrl"] is not None:
            ejecutar_async(llamar_seguro, video_widget_ref["ctrl"], "pause")
            estado["is_playing"] = False
        if not estado["player_open"] and not capa_reproductor.visible:
            capa_lista.visible = True
            refrescar_vista_base()
            return
        estado["anim_token"] += 1
        tok = estado["anim_token"]
        estado["player_open"] = False

        # Mostrar de nuevo la lista actualizada justo antes de deslizar hacia abajo
        if estado["active_tab"] in (0, 1):
            poblar_filas_media(p, es_video=(estado["active_tab"] == 1))
        contenedor_mini_barra.content = construir_mini_barra(p)
        capa_lista.visible = True
        actualizar_control(capa_lista)

        capa_reproductor.offset = crear_offset(0, 1.0)
        actualizar_control(capa_reproductor)

        async def _bajar():
            await asyncio.sleep(0.30)
            if estado["anim_token"] != tok or estado["player_open"]:
                return
            capa_reproductor.visible = False
            actualizar_control(capa_reproductor)

        ejecutar_async(_bajar)

    try:
        page.on_resized = refrescar_vista_base
    except Exception:
        pass

    # Arranque instantaneo + escaneo automatico en segundo plano
    refrescar_vista_base()
    ejecutar_async(escanear_async, False)
    ejecutar_async(bucle_reloj)


if __name__ == "__main__":
    if hasattr(ft, "run"):
        ft.run(main)
    else:
        ft.app(target=main)
