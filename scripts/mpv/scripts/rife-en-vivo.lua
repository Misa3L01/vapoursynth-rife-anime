-- rife-en-vivo.lua - Atajo y avisos para la interpolacion en tiempo real.
--
-- Ctrl+I prende y apaga la interpolacion, para comparar con el original.
--
-- Si el script de VapourSynth falla, mpv desactiva el filtro y sigue
-- reproduciendo el original sin avisar nada en pantalla: uno podria mirar un
-- episodio entero creyendo que esta interpolado. Este script lo avisa.
--
-- Lo carga mpv desde la configuracion de scripts\mpv, que solo usa
-- scripts\ver-en-vivo.bat. Igual no hace nada si falta el filtro "rife".

local apagado_a_mano = false

local function filtro()
    for _, f in ipairs(mp.get_property_native("vf") or {}) do
        if f.label == "rife" then return f end
    end
end

local function prendido(f) return f and f.enabled ~= false end

mp.register_event("file-loaded", function()
    if filtro() then
        mp.osd_message(string.format(
            "Interpolación RIFE en tiempo real · %s fps\nCtrl+I: comparar con el original",
            os.getenv("RT_FPS") or "48"), 5)
    end
end)

-- Cuando el filtro falla, mpv lo apaga por dentro pero la propiedad "vf" lo
-- sigue mostrando prendido (medido), asi que no sirve mirarla: se escuchan los
-- mensajes de mpv.
mp.enable_messages("error")
mp.register_event("log-message", function(e)
    local fallo = e.text:find("Disabling filter rife", 1, true)
        or (e.prefix == "vapoursynth" and e.level == "error")
    if fallo and filtro() then
        mp.osd_message("La interpolación falló y se está viendo el original.\n"
            .. "El error está en la consola de Ver-en-vivo, o en cache\\work\\en-vivo.log si se abrió desde la app.", 12)
        -- la app busca esta linea en el log para avisar tambien desde la ventana
        mp.msg.warn("INTERPOLACION FALLIDA: se reproduce el original")
    end
end)

mp.add_key_binding("ctrl+i", "rife-toggle", function()
    local f = filtro()
    if not f then
        mp.osd_message("Este video no se abrió con interpolación")
        return
    end
    apagado_a_mano = prendido(f)
    mp.command("vf toggle @rife")
    mp.osd_message(apagado_a_mano and "Interpolación: apagada (original)" or "Interpolación: prendida", 2)
end)
