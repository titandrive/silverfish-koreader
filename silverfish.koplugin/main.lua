--[[--
Traça: um bichinho virtual que se alimenta das letras que você lê.

Cada página lida (com pelo menos alguns segundos de leitura) vira comida.
O estado fica em settings/traca.lua; a imagem da tela de descanso em koreader/traca/.
]]

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Desenho = require("traca_desenho")
local Guarda = require("traca_guarda")
local T = require("traca_lingua").t
local Estado = require("traca_estado")
local Contagem = require("traca_contagem")
local Memoria = require("traca_memoria")
local Diario = require("traca_diario")
local Brood = require("traca_brood")
local Species = require("traca_species")
local TracaTela = require("traca_tela")
local Screensaver = require("ui/screensaver")

-- Nenhum erro da Traça interrompe a leitura: vai para o log; depois de 3 seguidos ela se cala
-- até o KOReader reiniciar e avisa uma vez (ver traca_guarda.lua e o fim deste arquivo).
Guarda.padrao:configurar(
    function(nome, err) logger.warn("Traça: erro em " .. tostring(nome) .. " (a leitura continua):", err) end,
    function()
        UIManager:nextTick(function()
            UIManager:show(InfoMessage:new{
                text = T"A Traça teve um problema e vai ficar quieta até você reiniciar o KOReader. Sua leitura não foi afetada.",
            })
        end)
    end)

local LETRAS_POR_SEGUNDO = 60    -- teto de velocidade de leitura
local LETRAS_ESTIMADAS = 1200    -- quando não dá para extrair o texto da página
local PAGINAS_ENTRE_IMAGENS = 10 -- de quantas em quantas páginas redesenha a tela de descanso

local Traca = WidgetContainer:extend{
    name = "traca",
    is_doc_only = false,
}

-- O KOReader mostra a tela de descanso antes de avisar os plugins que vai dormir (Screensaver:setup e show,
-- depois o evento Suspend). Para a fala ser escolhida quando o Kindle vai dormir, a Traça desenha a imagem
-- aqui, logo antes de o KOReader pegar a imagem da pasta. Embrulha uma vez só, mesmo se o plugin recarregar.
if not Screensaver.traca_setup_original then
    Screensaver.traca_setup_original = Screensaver.setup
    Screensaver.setup = function(...)
        local traca = Screensaver.traca_instancia
        if traca then pcall(traca.aoDormir, traca) end
        return Screensaver.traca_setup_original(...)
    end
end

function Traca:init()
    Screensaver.traca_instancia = self  -- a Traça aberta agora (biblioteca ou leitor)
    self.pasta = DataStorage:getDataDir() .. "/traca"
    self.imagem = self.pasta .. "/traca.png"
    self.db = LuaSettings:open(DataStorage:getSettingsDir() .. "/traca.lua")
    local agora = os.time()
    self.estado = Estado.normalizar(self.db:readSetting("estado"), agora)
    Estado.passarTempo(self.estado, agora)
    -- the brood: whoever is awake is self.estado; the others sleep in self.ninhada (traca_brood.lua)
    self.ninhada = Brood.normalize(self.db:readSetting("ninhada"), agora)
    Species.use(Brood.speciesOf(self.estado))
    self.paginas_sem_imagem = 0
    -- modo dev: com o arquivo koreader/traca/falhar, a digestão da página falha de propósito (nunca na versão
    -- da comunidade)
    local okV, Versao = pcall(require, "traca_versao")
    local publica = okV and type(Versao) == "table" and Versao.publica
    self.falha_teste = not publica and lfs.attributes(self.pasta .. "/falhar", "mode") == "file"
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    self:aplicarGesto()
    UIManager:nextTick(function() self:aoIniciar() end)
    -- cartão na tela inicial e botão no Simple UI, se ele estiver instalado
    local ok, Integracao = pcall(require, "traca_simpleui")
    if ok then
        Integracao.registrar(self)
    else
        logger.warn("Traça: integração com o Simple UI indisponível:", Integracao)
    end
end

function Traca:onDispatcherRegisterActions()
    Dispatcher:registerAction("traca_mostrar", {
        category = "none", event = "MostrarTraca", title = T"Traça: ver o bichinho", general = true,
    })
end

function Traca:addToMainMenu(menu_items)
    menu_items.traca = {
        text = T"Traça",
        sorting_hint = "tools",
        callback = function() self:onMostrarTraca() end,
    }
end

-- Telas da Traça abertas (a principal e as boas-vindas), de qualquer instância do plugin. Fica uma só por vez,
-- e ela fecha junto com a biblioteca ou o livro que a abriu. Sem isso, uma tela coberta por outra janela (ex.: o
-- Simple UI abre a Home por cima dela quando o Kindle acorda) ficava esquecida embaixo; ao sair do KOReader, que
-- só fecha quando não sobra janela, as telas esquecidas apareciam empilhadas.
local telas = setmetatable({}, { __mode = "k" })

local function fecharTelas(dono)
    for tela in pairs(telas) do
        if not dono or tela.traca == dono then
            telas[tela] = nil
            if not UIManager.isWidgetShown or UIManager:isWidgetShown(tela) then UIManager:close(tela) end
        end
    end
end

function Traca:mostrarTela(tela)
    fecharTelas()
    telas[tela] = true
    UIManager:show(tela)
end

function Traca:onCloseWidget()
    fecharTelas(self)
end

function Traca:onMostrarTraca()
    Estado.passarTempo(self.estado, os.time())
    local s = self.estado
    -- ainda ovo e sem ter passado pelas boas-vindas: mostra as boas-vindas antes
    if not s.boasvindas and s.letras < 3000 then
        return self:mostrarBoasVindas()
    end
    local tela = TracaTela:new{ traca = self }
    self:mostrarTela(tela)
    -- já nasceu e ainda não tem nome: pergunta uma vez, com a tela já desenhada por trás (traca_nome.lua)
    if require("traca_nome").devePerguntar(s) then
        UIManager:scheduleIn(0.5, function()
            local aberta = telas[tela] and (not UIManager.isWidgetShown or UIManager:isWidgetShown(tela))
            if aberta then tela:pedirNome(true) end
        end)
    end
    return true
end

function Traca:mostrarBoasVindas()
    local BoasVindas = require("traca_boasvindas")
    self:mostrarTela(BoasVindas:new{
        traca = self,
        ao_terminar = function() self:mostrarTela(TracaTela:new{ traca = self }) end,
    })
    return true
end

-- Primeira abertura e "abrir ao iniciar" (só uma vez por sessão do KOReader, na biblioteca)
local ja_abriu_nesta_sessao = false

--- Atende um toque no widget de Android (traca_widget.lua): abre a Traça, o último livro ou a tela inicial.
-- Devolve true se havia um pedido.
function Traca:atenderWidget()
    local okW, WidgetExport = pcall(require, "traca_widget")
    local acao = okW and WidgetExport.pedido(self.path)
    if not acao then return false end
    UIManager:scheduleIn(0.5, function()
        if acao == "silverfish" then
            self:onMostrarTraca()
        elseif acao == "livro" then
            local ultimo = G_reader_settings:readSetting("lastfile")
            local aberto = self.ui.document and self.ui.document.file
            if ultimo and ultimo ~= aberto and lfs.attributes(ultimo, "mode") == "file" then
                require("apps/reader/readerui"):showReader(ultimo)
            end
        elseif acao == "inicio" and self.ui.document then
            self.ui:handleEvent(require("ui/event"):new("Home"))
        end
    end)
    return true
end

function Traca:aoIniciar()
    if self:atenderWidget() then ja_abriu_nesta_sessao = true return end
    if ja_abriu_nesta_sessao or self.ui.document then return end
    ja_abriu_nesta_sessao = true
    local s = self.estado
    if not s.boasvindas and s.letras < 3000 then
        UIManager:scheduleIn(1, function() self:mostrarBoasVindas() end)
    elseif G_reader_settings:isTrue("traca_abrir_ao_iniciar") then
        UIManager:scheduleIn(1, function() self:onMostrarTraca() end)
    end
end

--- "Abrir ao iniciar" (escolhido nas boas-vindas; também no menu da tela dela). Sem argumento, só lê.
function Traca:abrirAoIniciar(ligar)
    if ligar ~= nil then G_reader_settings:saveSetting("traca_abrir_ao_iniciar", ligar or nil) end
    return G_reader_settings:isTrue("traca_abrir_ao_iniciar")
end

--- Atalho por gesto ligado? (escolhido nas boas-vindas; também no menu da tela dela). Sem argumento, só lê.
function Traca:atalhoGesto(ligar)
    if ligar ~= nil then
        G_reader_settings:saveSetting("traca_gesto", ligar or nil)
        self:aplicarGesto()
    end
    return G_reader_settings:isTrue("traca_gesto")
end

-- Atalho por gesto: segurar o dedo no canto superior direito abre a Traça.
function Traca:aplicarGesto()
    if not (self.ui and self.ui.registerTouchZones) then return end
    if self.ui.unregisterTouchZones then
        pcall(self.ui.unregisterTouchZones, self.ui, { { id = "traca_gesto" } })
    end
    if G_reader_settings:isTrue("traca_gesto") then
        self.ui:registerTouchZones({{
            id = "traca_gesto",
            ges = "hold",
            screen_zone = { ratio_x = 0.85, ratio_y = 0, ratio_w = 0.15, ratio_h = 0.1 },
            handler = function() return self:onMostrarTraca() end,
        }})
    end
end

-- Simple UI: está instalado? E o cartão da Traça está ligado na Home?
function Traca:temSimpleUI()
    local ok = pcall(require, "modules/moduleregistry")
    return ok
end

-- Simple UI 3: a tela inicial é uma lista de páginas com os módulos; o cartão aparece se estiver numa delas.
-- Põe no fim da primeira página ou tira, como o editor de layout do próprio Simple UI. nil = não é o Simple UI 3.
local function cartaoNoLayout(ligar)
    local ok_l, Layout = pcall(require, "infra/sui_layout")
    if not (ok_l and type(Layout) == "table" and Layout.load and Layout.save and Layout.findPage) then return nil end
    local ok, esta = pcall(function()
        local layout = Layout.load()
        if type(layout) ~= "table" or type(layout.pages) ~= "table" then return nil end
        local esta = Layout.findPage(layout, "traca_cartao") ~= nil
        if ligar ~= nil and (ligar and true or false) ~= esta then
            if ligar then
                if not layout.pages[1] then layout.pages[1] = { id = 1, modules = {} } end
                table.insert(layout.pages[1].modules, "traca_cartao")
            else
                Layout.remove(layout, nil, "traca_cartao")
            end
            Layout.save(layout)
            esta = Layout.findPage(layout, "traca_cartao") ~= nil
        end
        return esta
    end)
    if ok then return esta end
end

function Traca:cartaoSimpleUI(ligar)
    local no_layout = cartaoNoLayout(ligar)
    if no_layout ~= nil then return no_layout end
    -- Simple UI 2: uma chave liga e desliga o cartão
    local ok, SUISettings = pcall(require, "infra/sui_store")
    if not ok or not SUISettings then return false end
    local chave = "simpleui_hs_traca_cartao_enabled"
    if ligar ~= nil then pcall(SUISettings.saveSetting, SUISettings, chave, ligar and true or false) end
    local okr, v = pcall(SUISettings.readSetting, SUISettings, chave)
    if not okr or v == nil then return true end
    return v == true
end

-- Bookshelf 6.1 ou mais novo: põe a Traça na prateleira inicial (só quando a pessoa escolhe, nas boas-vindas).
local function kitBookshelf()
    local ok, Kit = pcall(require, "lib/bookshelf_module_kit")
    if ok and type(Kit) == "table" and Kit.setOnHomeShelf and Kit.onHomeShelf then return Kit end
end

function Traca:temBookshelf()
    return kitBookshelf() ~= nil
end

--- A Traça está na prateleira inicial do Bookshelf? Com `ligar`, põe ou tira antes de responder.
function Traca:cartaoBookshelf(ligar)
    local Kit = kitBookshelf()
    if not Kit then return false end
    if ligar ~= nil then pcall(Kit.setOnHomeShelf, "silverfish", ligar and true or false) end
    local ok, v = pcall(Kit.onHomeShelf, "silverfish")
    return ok and v == true
end

-- Leitura ------------------------------------------------------------------

function Traca:onPageUpdate(pageno)
    if not self.ui.document or type(pageno) ~= "number" then return end
    self:contarPaginaAtual()
    self.pagina = pageno
    self.pagina_desde = os.time()
end

--- Dá a página que estava aberta para a Traça comer.
-- Conta como as estatísticas do KOReader (uma vez por livro, tempo mínimo delas, e nada com elas desligadas); só molda a traça
-- (temas, personagens, traços, lembranças) se foi lida de verdade (traca_contagem.lua).
function Traca:contarPaginaAtual()
    local p, desde = self.pagina, self.pagina_desde
    if not p or not desde then return end
    local tempo = os.time() - desde
    local estatisticas = G_reader_settings:readSetting("statistics")
    -- estatísticas de leitura desligadas (no menu, num gesto ou num perfil): ela também não conta nem come
    if type(estatisticas) == "table" and estatisticas.is_enabled == false then return end
    if tempo < Contagem.minimoSegundos(estatisticas) then return end
    local onde = self:ondeEstou(p)
    local livro = onde.livro or "?"
    local total = self.ui.document and self.ui.document:getPageCount()
    local nova = Contagem.primeiraVez(self.estado, livro, p, total, os.time())
    local texto = self:textoDaPagina(p)
    local reais = texto and Estado.contarLetras(texto) or LETRAS_ESTIMADAS
    -- molda a traça na primeira passagem que for leitura de verdade (pode ser depois de folhear)
    local lida = not Contagem.jaLida(self.estado, livro, p)
        and Contagem.lidaDeVerdade(self.estado, tempo, reais, onde.capitulo, texto)
    if not nova and not lida then return end
    if lida then Contagem.marcarLida(self.estado, livro, p) end
    local letras = nova and math.min(reais, tempo * LETRAS_POR_SEGUNDO) or 0
    self:alimentar(letras, Estado.palavraMaisLonga(texto), onde, lida and texto or nil, nova)
end

--- Livro e capítulo da página (para a "última refeição").
function Traca:ondeEstou(p)
    local onde = {}
    pcall(function()
        local props = self.ui.doc_props
        onde.livro = props and (props.display_title or props.title)
        onde.autor = props and props.authors and props.authors:gsub("\n.*", "")
        onde.etiquetas = props and props.keywords  -- assunto do EPUB, uma etiqueta por linha (traca_banco/generos.lua)
        onde.arquivo = self.ui.document and self.ui.document.file
        if self.ui.toc then onde.capitulo = self.ui.toc:getTocTitleByPage(p) end
        local total = self.ui.document and self.ui.document:getPageCount()
        if total and total > 0 then
            onde.progresso = math.min(1, p / total)
            onde.fim_historia = self:fimDaHistoria(total)
        end
    end)
    if onde.capitulo == "" then onde.capitulo = nil end
    return onde
end

--- Progresso (0 a 1) em que a história acaba, pelo sumário (Diario.fimDaHistoria): notas, cronologia,
-- posfácio e propaganda depois dela não contam para terminar o livro. Refeito quando o total de páginas
-- muda (fonte, margens); nil quando o sumário não ajuda (aí vale o 98% do arquivo).
function Traca:fimDaHistoria(total)
    if self.fim_historia_total ~= total then
        self.fim_historia_total, self.fim_historia = total, nil
        local toc = self.ui.toc
        if toc and toc.fillToc then toc:fillToc() end
        local itens = {}
        for _, item in ipairs(toc and toc.toc or {}) do
            local pagina = item.fixed_page or item.page  -- fixed_page: item fora de ordem corrigido pelo KOReader
            if type(pagina) == "number" then
                itens[#itens + 1] = { titulo = item.title, pagina = pagina, nivel = item.depth }
            end
        end
        local fim = Diario.fimDaHistoria(itens, total)
        if fim then self.fim_historia = fim / total end
    end
    return self.fim_historia
end

--- Reserva para o fim do livro: você marcou o livro como terminado no KOReader (Diario.statusKOReader).
-- Devolve true quando isso terminou o livro agora.
function Traca:conferirTerminado()
    if not self.ui.document or self.estado.dev_simulacao then return false end
    local resumo = self.ui.doc_settings and self.ui.doc_settings:readSetting("summary")
    local livro = self:ondeEstou(self.pagina or 1).livro
    return Diario.statusKOReader(self.estado, Memoria, livro, type(resumo) == "table" and resumo.status or nil,
        os.time()) == true
end

function Traca:onReaderReady()
    if self:conferirTerminado() then self:salvar(true) end
end

function Traca:textoDaPagina(p)
    local doc = self.ui.document
    local ok, texto = pcall(function()
        if self.ui.rolling then
            if p >= doc:getPageCount() then return end
            local xp0, xp1 = doc:getPageXPointer(p), doc:getPageXPointer(p + 1)
            if not (xp0 and xp1) then return end
            local r = doc:getTextFromXPointers(xp0, xp1)
            return type(r) == "table" and r.text or r
        elseif doc.getPageTextBoxes then
            local caixas = doc:getPageTextBoxes(p)
            if not caixas then return end
            local partes = {}
            for _, linha in ipairs(caixas) do
                for _, palavra in ipairs(linha) do
                    if palavra.word then partes[#partes + 1] = palavra.word end
                end
            end
            return table.concat(partes, " ")
        end
    end)
    if ok and type(texto) == "string" and texto ~= "" then return texto end
    if not ok then logger.dbg("Traça: sem texto da página", p, texto) end
end

-- contar: false quando a página já foi contada e agora só está sendo digerida (sem contar de novo).
function Traca:alimentar(letras, palavra, onde, texto, contar)
    if self.falha_teste then error("falha de teste injetada (modo dev: koreader/traca/falhar)") end
    if self.estado.dev_simulacao then return end  -- simulação de demo: congelada, leitura real não entra
    local agora = os.time()
    local ocorreu = contar ~= false and Estado.comer(self.estado, letras, palavra, agora, onde) or {}
    pcall(Memoria.digerir, self.estado, texto, onde, agora, contar)
    self.paginas_sem_imagem = self.paginas_sem_imagem + 1
    local aviso
    if ocorreu.evoluiu then
        aviso = ocorreu.evoluiu.aviso or string.format(Species.texto("virou"), ocorreu.evoluiu.titulo)
    elseif ocorreu.acordou then
        aviso = Species.texto("saiu")
    end
    if ocorreu.fim_ciclo then
        return self:fimDoCiclo()
    end
    if aviso then
        Memoria.anotar(self.estado, agora, aviso)
        UIManager:show(InfoMessage:new{ text = aviso, timeout = 4 })
        self:salvar(true)
    elseif self.paginas_sem_imagem >= PAGINAS_ENTRE_IMAGENS then
        self:salvar(true)
    end
end

--- Fim do ciclo: a anciã põe um ovo e morre; fica o memorial na linhagem.
function Traca:fimDoCiclo()
    local agora = os.time()
    local s = self.estado
    local citacao
    pcall(function()
        local todos = {}
        for _, L in ipairs(TracaTela.lerSublinhados()) do
            for _, it in ipairs(L.itens) do todos[#todos + 1] = "“" .. it.texto:gsub("%s+", " ") .. "” — " .. L.livro end
        end
        if #todos > 0 then citacao = todos[math.random(#todos)] end
    end)
    local memorial = Estado.renascer(s, agora, { citacao = citacao })
    if Diario.banco() then  -- the silverfish's first diary line; a species with no diary yet writes none
        Memoria.anotar(s, agora, string.format(T"Nasci do ovo da geração %d.%s", memorial.geracao,
            s.heranca and string.format(T" Tenho uma obsessão herdada: %s. Nunca pedi por isso.", Memoria.NOMES_TEMA[s.heranca]) or ""))
    end
    self:salvar(true)
    UIManager:show(InfoMessage:new{
        text = string.format(Species.texto("fim"), memorial.geracao, memorial.ultimas),
    })
end

-- Modo dev: simulação de endgame ---------------------------------------------------
-- O estado simulado (koreader/traca/simulacao.lua, gerado por ferramentas/simular_endgame.lua)
-- entra no lugar do real, que fica guardado em settings/traca.lua ("estado_real") até voltar.

function Traca:emSimulacao()
    return self.db:readSetting("estado_real") ~= nil
end

function Traca:carregarSimulacao()
    local arquivo = self.pasta .. "/simulacao.lua"
    if lfs.attributes(arquivo, "mode") ~= "file" then return false end
    local ok, sim = pcall(function() return LuaSettings:open(arquivo):readSetting("estado") end)
    if not ok or type(sim) ~= "table" then return false end
    if not self:emSimulacao() then self.db:saveSetting("estado_real", self.estado) end
    self.estado = Estado.normalizar(sim, os.time())
    self.estado.dev_simulacao = true
    Species.use(Brood.speciesOf(self.estado))
    Estado.passarTempo(self.estado, os.time())
    self:salvar(true)
    return true
end

function Traca:voltarEstadoReal()
    local real = self.db:readSetting("estado_real")
    if not real then return false end
    self.estado = Estado.normalizar(real, os.time())
    self.db:delSetting("estado_real")
    Species.use(Brood.speciesOf(self.estado))
    self:salvar(true)
    return true
end

--- Puts the awake creature to sleep and wakes `id` (a new egg if it has never hatched). Not during a simulation.
function Traca:acordar(id)
    if self:emSimulacao() or id == Brood.speciesOf(self.estado) then return false end
    self.estado = Brood.wake(self.estado, self.ninhada, id, os.time())
    self:salvar(true)
    return true
end

function Traca:carinho()
    local ok = Estado.carinho(self.estado, os.time())
    if ok then self:salvar(true) end
    return ok
end

-- Persistência -------------------------------------------------------------

function Traca:salvar(com_imagem)
    self.db:saveSetting("estado", self.estado)
    if next(self.ninhada.sleeping) then self.db:saveSetting("ninhada", self.ninhada) else self.db:delSetting("ninhada") end
    self.db:flush()
    if com_imagem then self:gerarImagem() end
    -- o widget de Android lê widget/estado.json na pasta do plugin (traca_widget.lua)
    local okW, WidgetExport = pcall(require, "traca_widget")
    if okW then WidgetExport.exportar(self.path, self.estado) end
end

-- escolher = true só quando o Kindle vai dormir (aoDormir): nos outros redesenhos, que ninguém vê, a fala
-- é a última escolhida e nada se gasta (Estado.falaDescanso).
function Traca:gerarImagem(forcar, escolher)
    if not forcar and not self:telaDescansoAtiva() then return end
    if lfs.attributes(self.pasta, "mode") ~= "directory" then lfs.mkdir(self.pasta) end
    local ok, err = TracaTela.gerarTelaDescanso(self.estado, self.imagem, os.time(), escolher)
    if not ok then logger.warn("Traça: falha ao gerar a tela de descanso:", err) end
    self.paginas_sem_imagem = 0
end

--- O Kindle vai dormir (chamado antes de o KOReader mostrar a tela de descanso): escolhe a fala e desenha a imagem.
function Traca:aoDormir()
    if not self:telaDescansoAtiva() then return end
    Estado.passarTempo(self.estado, os.time())
    self:gerarImagem(false, true)
end

function Traca:onCloseDocument()
    self:contarPaginaAtual()
    self:conferirTerminado()
    self:salvar(true)
end

function Traca:onSuspend()
    self:contarPaginaAtual()
    self:conferirTerminado()
    Estado.passarTempo(self.estado, os.time())
    self:salvar(true)
end

function Traca:onResume()
    if self.pagina then self.pagina_desde = os.time() end
    Estado.passarTempo(self.estado, os.time())
    self:gerarImagem() -- deixa pronta a imagem para a próxima vez que o Kindle dormir
    self:atenderWidget()  -- voltou para a frente por um toque no widget?
end

function Traca:onFlushSettings()
    self:salvar(false)
end

-- Tela de descanso -----------------------------------------------------------

function Traca:telaDescansoAtiva()
    return G_reader_settings:readSetting("screensaver_type") == "random_image"
        and G_reader_settings:readSetting("screensaver_dir") == self.pasta
end

--- Liga ou desliga a Traça como tela de descanso, guardando a configuração anterior.
function Traca:alternarTelaDescanso()
    if self:telaDescansoAtiva() then
        local ant = self.db:readSetting("tela_anterior") or {}
        G_reader_settings:saveSetting("screensaver_type", ant.tipo or "disable")
        if ant.pasta then
            G_reader_settings:saveSetting("screensaver_dir", ant.pasta)
        else
            G_reader_settings:delSetting("screensaver_dir")
        end
        if ant.mensagem ~= nil then
            G_reader_settings:saveSetting("screensaver_show_message", ant.mensagem)
        end
        self.db:delSetting("tela_anterior")
    else
        self.db:saveSetting("tela_anterior", {
            tipo = G_reader_settings:readSetting("screensaver_type"),
            pasta = G_reader_settings:readSetting("screensaver_dir"),
            mensagem = G_reader_settings:readSetting("screensaver_show_message"),
        })
        self:gerarImagem(true)
        G_reader_settings:saveSetting("screensaver_type", "random_image")
        G_reader_settings:saveSetting("screensaver_dir", self.pasta)
        G_reader_settings:saveSetting("screensaver_show_message", false)
    end
    self:salvar(false)
end

--- Modo dev: liga ou desliga a falha de teste na leitura (cria ou apaga koreader/traca/falhar).
function Traca:alternarFalhaTeste()
    local arquivo = self.pasta .. "/falhar"
    if self.falha_teste then
        os.remove(arquivo)
        self.falha_teste = false
    else
        if lfs.attributes(self.pasta, "mode") ~= "directory" then lfs.mkdir(self.pasta) end
        local f = io.open(arquivo, "w")
        if f then f:write("teste\n"); f:close() end
        self.falha_teste = true
    end
    return self.falha_teste
end

-- Todo ponto em que o KOReader chama a Traça passa pelo guarda.
Guarda.padrao:envolver(Traca, { "onPageUpdate", "onCloseDocument", "onSuspend", "onResume", "onFlushSettings",
    "onMostrarTraca", "aoIniciar", "mostrarBoasVindas", "onReaderReady", "aoDormir", "onCloseWidget" })

return Traca
