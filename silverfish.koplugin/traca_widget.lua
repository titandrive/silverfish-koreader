--[[--
Export para o widget de Android (Silverfish Widget): a cada vez que a Traça salva, escreve
widget/estado.json dentro da pasta do plugin, com o que o widget precisa para se desenhar sozinho
(nome, fase, progresso, barriga, humor, a fala, e os desenhos com as cores). O widget lê esse arquivo
da pasta do plugin; nada aqui muda o estado da Traça.
]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Desenho = require("traca_desenho")
local Estado = require("traca_estado")
local Species = require("traca_species")

local Widget = {}

Widget.FORMATO = 1

local function desenho(nome)
    local real = Desenho.resolver(nome)
    local cor = Species.sprites(true)
    local linhas = cor[real] or Species.sprites(false)[real] or {}
    local cores = {}
    for ch, v in pairs(cor._cores or {}) do cores[ch] = v end
    return { nome = real, linhas = linhas, cores = cores }
end

-- A fala, sem gastar nada: a lista de recentes e as falas guardadas (lembrança, comentário, cartão) voltam
-- como estavam.
local function falaSemEfeito(s, agora)
    local recentes = {}
    for i, v in ipairs(s.falas_recentes or {}) do recentes[i] = v end
    local guardados = {}
    for _, k in ipairs({ "lembranca_pendente", "comentario_pendente", "cartao_pendente" }) do
        local t = s[k]
        if type(t) == "table" then guardados[k] = { t, t.usado, t.nao_coube } end
    end
    local ok, texto = pcall(Estado.fala, s, agora, nil, nil, "home")
    s.falas_recentes = recentes
    for _, g in pairs(guardados) do g[1].usado, g[1].nao_coube = g[2], g[3] end
    return ok and texto or nil
end

-- Faixas de rótulo (barriga ou humor) para o widget escolher o rótulo quando o valor cair com o tempo:
-- { {min, rótulo}, ... } do maior para o menor.
local function faixas(s, campo, rotulo)
    local out, ultimo = {}, nil
    for v10 = 1000, 0, -5 do
        local v = v10 / 10
        local falso = { barriga = s.barriga, humor = s.humor, letras = s.letras, dev_fase = s.dev_fase }
        falso[campo] = v
        local ok, r = pcall(rotulo, falso)
        if ok and r ~= ultimo then
            if ultimo then out[#out].min = v + 0.5 end
            out[#out + 1] = { min = 0, rotulo = r }
            ultimo = r
        end
    end
    return out
end

-- O que ela responde a um carinho, como na tela dela (TracaTela:carinho): algumas falas para quando conta
-- (as da espécie, se tiver; a traça tem uma só), a de quando já chega, e a de quando está no casulo.
local function falasDeCarinho(s)
    local T = require("traca_lingua").t
    local aceito, visto = {}, {}
    for _ = 1, 12 do
        local ok, f = pcall(Estado.falaPropria, s, "carinho")
        if ok and f and not visto[f] then visto[f] = true; aceito[#aceito + 1] = f end
    end
    if #aceito == 0 then aceito[1] = T"Hm. Tá. Pode continuar." end
    local okC, casulo = pcall(Estado.falaPropria, s, "casulo")
    return {
        aceito = aceito,
        chega = T"Já chega de carinho por agora.",
        casulo = (okC and casulo) or T"(escondida na lombada; leia uma página para ela sair)",
    }
end

function Widget.dados(s, agora)
    local fase = Estado.fase(s)
    local prog = Estado.progressoFase(s)
    return {
        formato = Widget.FORMATO,
        salvo_em = agora,
        nome = s.nome,
        geracao = s.geracao or 1,
        fase = fase.nome,
        fase_titulo = fase.titulo,
        proxima_titulo = prog.proxima and prog.proxima.titulo or nil,
        fracao = prog.fracao,
        paginas_para_proxima = prog.paginas,
        paginas = s.paginas or 0,
        paginas_hoje = Estado.paginasHoje(s, agora),
        barriga = s.barriga,
        humor = s.humor,
        hibernando = s.hibernando == true,
        fome_por_hora = Estado.FOME_POR_HORA,
        humor_por_hora = Estado.HUMOR_POR_HORA,
        faixas_barriga = faixas(s, "barriga", Estado.rotuloBarriga),
        faixas_humor = faixas(s, "humor", Estado.rotuloHumor),
        fala = falaSemEfeito(s, agora),
        acordada = desenho(Estado.sprite(s, agora)),
        dormindo = desenho(Estado.sprite(s, agora, true)),
        -- de noite (23h às 6h) ela dorme, a não ser que tenha lido há pouco
        lendo_ate = s.ultima_refeicao and (s.ultima_refeicao + Estado.LENDO_AGORA) or 0,
        -- Cada cara da fase, para o widget escolher como Estado.expressao, com o tempo passando sem salvar:
        -- casulo (barriga vazia há hiberna_apos), triste (barriga ou humor abaixo de 25), dormindo (de noite),
        -- feliz (comeu há menos de refeicao_recente, ou humor 75 ou mais), normal.
        -- (Por enquanto só dormir tem desenho próprio, repouso_<fase>, como na tela da Traça; o ovo é o ovo.
        -- As outras caras caem no desenho da fase, e passam a ter o seu se um dia forem desenhadas.)
        rostos = (function()
            local fase = Estado.fase(s).nome
            local r = {}
            for _, e in ipairs({ "normal", "feliz", "triste", "casulo" }) do
                r[e] = desenho(fase .. "_" .. e)
            end
            local repouso = "repouso_" .. fase
            r.dormindo = desenho(fase ~= "ovo" and Desenho.resolver(repouso) == repouso and repouso or fase)
            return r
        end)(),
        -- Carinho pelo widget (tocar a Traça): a regra é a de Estado.carinho, e as falas, as da tela dela.
        carinho_em = s.carinho_em or 0,
        carinho_intervalo = Estado.CARINHO_INTERVALO,
        falas_carinho = falasDeCarinho(s),
        ultima_refeicao = s.ultima_refeicao or 0,
        refeicao_recente = Estado.REFEICAO_RECENTE,
        vazio_desde = s.vazio_desde,
        hiberna_apos = Estado.HIBERNA_APOS,
    }
end

--- Escreve <pasta do plugin>/widget/estado.json (por um arquivo temporário, para o widget nunca ler pela metade).
function Widget.exportar(pasta_plugin, s)
    if type(s) ~= "table" or s.dev_simulacao then return end
    local ok, err = pcall(function()
        local dir = pasta_plugin .. "/widget"
        if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
        local texto = require("json").encode(Widget.dados(s, os.time()))
        local tmp = dir .. "/estado.json.tmp"
        local f = assert(io.open(tmp, "w"))
        f:write(texto)
        f:close()
        assert(os.rename(tmp, dir .. "/estado.json"))
    end)
    if not ok then logger.warn("Traça: falha ao exportar para o widget:", err) end
end

-- Pedidos do widget ------------------------------------------------------------

-- Um toque no widget deixa widget/abrir ("silverfish", "livro" ou "inicio", e a hora) e abre o KOReader;
-- aqui ele é atendido. Um pedido velho (o KOReader não abriu logo) é jogado fora sem fazer nada.
local VALIDADE = 60

--- Os carinhos dados pelo widget desde a última vez (widget/carinhos, uma hora por linha), já apagados do
-- arquivo, em ordem. O widget não mexe no estado da Traça (o KOReader o guarda na memória e o salvaria por
-- cima): ele anota, e a Traça aplica aqui.
function Widget.carinhos(pasta_plugin)
    local arquivo = pasta_plugin .. "/widget/carinhos"
    if lfs.attributes(arquivo, "mode") ~= "file" then return {} end
    local f = io.open(arquivo, "r")
    local texto = f and f:read("*a") or ""
    if f then f:close() end
    os.remove(arquivo)
    local horas = {}
    for h in texto:gmatch("%d+") do horas[#horas + 1] = tonumber(h) end
    table.sort(horas)
    return horas
end

--- Lê e apaga o pedido do widget, se houver um recente. Devolve "silverfish", "livro", "inicio" ou nil.
function Widget.pedido(pasta_plugin)
    local arquivo = pasta_plugin .. "/widget/abrir"
    if lfs.attributes(arquivo, "mode") ~= "file" then return nil end
    local f = io.open(arquivo, "r")
    local texto = f and f:read("*a") or ""
    if f then f:close() end
    os.remove(arquivo)
    local acao, hora = texto:match("^(%a+)%s+(%d+)")
    hora = tonumber(hora)
    if not acao or not hora or math.abs(os.time() - hora) > VALIDADE then return nil end
    return acao
end

return Widget
