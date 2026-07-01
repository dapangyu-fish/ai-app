"""Demo replay — 免登录 super-demo 模式的服务端核心。

特殊 UUID 的 AI 任务不会路由到任何 agent-node，也不会真正创建 FaaS：
chat_start 识别到特殊 session_id 后直接走这里，用预录的 jsonl 通过 SSE 回放
（带极小 sleep，体感像一次很快的真实生成），最后给出一个**真实**的临时
JSON-app 链接（从随包的 app.json 现场重新上传，避免 24h presigned 过期）。

录制（一次性，在部署主机）：设置环境变量
  AI_DEMO_RECORD_SESSION_ID=<某次真实生成的 session_id>
  AI_DEMO_RECORD_PATH=backend/demo_replays/<base>.jsonl
ai_session.SessionStore.append_event / set_status 会把业务事件 tee 成 jsonl。
再把那次真实生成上传的 app.json 存成 backend/demo_replays/<base>.app.json。

详见 memory: demo-replay-mode。隔离：demo 是一个**真实但专用**的 Supabase 账号，
session 的 meta.user_id = 该账号 uid，stream/result 的归属校验天然隔离真实用户；
demo 永不进 submit_worker → 不占队列/配额/lease，也不碰 agent-node。
"""
import json
import logging
import os
import time

from flask import jsonify

import ai_session

logger = logging.getLogger(__name__)

REPLAY_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "demo_replays")

# 特殊 demo UUID → 回放文件 basename（backend/demo_replays/<base>.jsonl[/.app.json]）
DEMO_SESSIONS = {
    "00000000-0000-0000-0000-000000000001": "forum_0001",
    "00000000-0000-0000-0000-000000000002": "pomodoro_0002",
    "00000000-0000-0000-0000-000000000003": "calculator",
    "00000000-0000-0000-0000-000000000004": "demo_5pages",
    "00000000-0000-0000-0000-000000000005": "demo_media",
    "00000000-0000-0000-0000-000000000006": "demo_video_browser",
    "00000000-0000-0000-0000-000000000007": "framework_quality_camera_inspection",
    "00000000-0000-0000-0000-000000000008": "framework_quality_course_player",
    "00000000-0000-0000-0000-000000000009": "framework_quality_ops_dashboard",
    "00000000-0000-0000-0000-000000000010": "framework_quality_smart_home",
    "00000000-0000-0000-0000-000000000011": "framework_quality_travel_pass",
    "00000000-0000-0000-0000-000000000012": "match3-pixel",
    "00000000-0000-0000-0000-000000000013": "native_quality_budget",
    "00000000-0000-0000-0000-000000000014": "native_quality_crm",
    "00000000-0000-0000-0000-000000000015": "native_quality_habits",
    "00000000-0000-0000-0000-000000000016": "native_quality_notes",
    "00000000-0000-0000-0000-000000000017": "native_quality_workout",
    "00000000-0000-0000-0000-000000000018": "super-app-demo",
    "00000000-0000-0000-0000-000000000019": "text-collector",
    "00000000-0000-0000-0000-000000000020": "demo_2048",
    "00000000-0000-0000-0000-000000000021": "demo_snake",
    "00000000-0000-0000-0000-000000000022": "demo_flappy_bird",
    # 全栈论坛（广场社区）：真实生成录制 + 专属公开 FaaS 服务组 demo-forum（demo 账号持有，
    # access_policy=public），免登录用户回放后可真创建板块/发帖/楼中楼/加好友私信。
    "00000000-0000-0000-0000-000000000023": "community_forum_0023",
}

DEMO_PROMPTS = [
    # 客户端 demo 选择列表的单一真相源（服务端下发，加 demo 只改这里 + DEMO_SESSIONS，
    # 不用客户端发版）。顺序即展示顺序。GET /api/ai/demo/list 返回它。
    {
        "uuid": "00000000-0000-0000-0000-000000000001",
        "title": {"zh": "论坛 / 贴吧类 App（全栈）", "en": "Forum / message-board App (full-stack)", "de": "Forum-/Message-Board-App (Full-Stack)", "es": "App de foro / tablón de mensajes (full-stack)", "fr": "App de forum / babillard (full-stack)", "pt": "App de fórum / quadro de mensagens (full-stack)", "ca": "App de fòrum / tauler de missatges (full-stack)", "hi": "फ़ोरम / मैसेज-बोर्ड ऐप (फ़ुल-स्टैक)", "ko": "포럼 / 게시판 앱 (풀스택)", "ja": "フォーラム / 掲示板アプリ（フルスタック）", "it": "App di forum / bacheca (full-stack)"},
        "prompt": {"zh": "创建一个论坛类型的 App：要有用户个人页面（显示真实头像）、可以创建讨论区（类似贴吧的「吧」）、可以发帖、评论、点赞。", "en": "Create a forum-style App: it needs user profile pages (showing real avatars), the ability to create discussion boards (like the boards on a message board), and to post, comment, and like.", "de": "Erstelle eine Forum-App: Sie braucht Benutzerprofilseiten (mit echten Avataren), die Möglichkeit, Diskussionsforen zu erstellen (wie die Boards in einem Forum), sowie Posten, Kommentieren und Liken.", "es": "Crea una App de tipo foro: necesita páginas de perfil de usuario (que muestren avatares reales), poder crear foros de debate (como los tablones de un foro), y publicar, comentar y dar me gusta.", "fr": "Crée une App de type forum : il faut des pages de profil utilisateur (affichant de vrais avatars), la possibilité de créer des espaces de discussion (comme les forums), et de publier, commenter et aimer.", "pt": "Crie um App de fórum: precisa de páginas de perfil de usuário (mostrando avatares reais), poder criar áreas de discussão (como os fóruns), e postar, comentar e curtir.", "ca": "Crea una App de tipus fòrum: necessita pàgines de perfil d'usuari (que mostrin avatars reals), poder crear espais de debat (com els fòrums), i publicar, comentar i fer m'agrada.", "hi": "एक फ़ोरम-शैली की ऐप बनाएँ: इसमें उपयोगकर्ता प्रोफ़ाइल पेज (असली अवतार दिखाते हुए), चर्चा बोर्ड बनाने की सुविधा (जैसे फ़ोरम के बोर्ड), और पोस्ट करना, टिप्पणी करना व लाइक करना होना चाहिए।", "ko": "포럼형 앱을 만들어 주세요: 사용자 프로필 페이지(실제 아바타 표시), 토론 게시판 생성 기능(게시판의 판과 유사), 그리고 글 작성, 댓글, 좋아요 기능이 필요합니다.", "ja": "フォーラム型のアプリを作ってください：ユーザーのプロフィールページ（実際のアバターを表示）、掲示板（板のようなもの）を作成できること、投稿・コメント・いいねができることが必要です。", "it": "Crea un'App in stile forum: servono pagine profilo utente (con avatar reali), la possibilità di creare bacheche di discussione (come i forum), e di pubblicare, commentare e mettere mi piace."},
    },
    {
        "uuid": "00000000-0000-0000-0000-000000000002",
        "title": {"zh": "番茄钟（纯前端）", "en": "Pomodoro timer (front-end only)", "de": "Pomodoro-Timer (nur Frontend)", "es": "Temporizador Pomodoro (solo front-end)", "fr": "Minuteur Pomodoro (front-end uniquement)", "pt": "Temporizador Pomodoro (apenas front-end)", "ca": "Temporitzador Pomodoro (només front-end)", "hi": "पोमोडोरो टाइमर (केवल फ्रंट-एंड)", "ko": "뽀모도로 타이머 (프런트엔드 전용)", "ja": "ポモドーロタイマー（フロントエンドのみ）", "it": "Timer Pomodoro (solo front-end)"},
        "prompt": {"zh": "做一个番茄钟：25 分钟倒计时，开始 / 暂停 / 重置，结束提醒。", "en": "Build a Pomodoro timer: a 25-minute countdown, with start / pause / reset, and an alert when it ends.", "de": "Baue einen Pomodoro-Timer: 25-Minuten-Countdown mit Start / Pause / Zurücksetzen und einer Erinnerung am Ende.", "es": "Haz un temporizador Pomodoro: cuenta atrás de 25 minutos, con iniciar / pausar / reiniciar y aviso al terminar.", "fr": "Crée un minuteur Pomodoro : compte à rebours de 25 minutes, avec démarrer / pause / réinitialiser et une alerte à la fin.", "pt": "Faça um temporizador Pomodoro: contagem regressiva de 25 minutos, com iniciar / pausar / redefinir e aviso ao terminar.", "ca": "Fes un temporitzador Pomodoro: compte enrere de 25 minuts, amb iniciar / pausar / reiniciar i avís en acabar.", "hi": "एक पोमोडोरो टाइमर बनाएँ: 25 मिनट की उलटी गिनती, शुरू / रोकें / रीसेट, और समाप्त होने पर सूचना।", "ko": "뽀모도로 타이머를 만들어 주세요: 25분 카운트다운, 시작 / 일시정지 / 초기화, 종료 시 알림.", "ja": "ポモドーロタイマーを作ってください：25分のカウントダウン、開始／一時停止／リセット、終了時の通知。", "it": "Crea un timer Pomodoro: conto alla rovescia di 25 minuti, con avvio / pausa / reset e avviso al termine."},
    },
    {
        "uuid": "00000000-0000-0000-0000-000000000003",
        "title": {"zh": "计算器", "en": "Calculator", "de": "Rechner", "es": "Calculadora", "fr": "Calculatrice", "pt": "Calculadora", "ca": "Calculadora", "hi": "कैलकुलेटर", "ko": "계산기", "ja": "電卓", "it": "Calcolatrice"},
        "prompt": {"zh": "做一个计算器，支持加减乘除、百分比和清除。", "en": "Build a calculator that supports add, subtract, multiply, divide, percentage, and clear.", "de": "Baue einen Rechner mit Addition, Subtraktion, Multiplikation, Division, Prozent und Löschen.", "es": "Haz una calculadora con suma, resta, multiplicación, división, porcentaje y borrar.", "fr": "Crée une calculatrice prenant en charge l'addition, la soustraction, la multiplication, la division, le pourcentage et l'effacement.", "pt": "Faça uma calculadora com adição, subtração, multiplicação, divisão, porcentagem e limpar.", "ca": "Fes una calculadora amb suma, resta, multiplicació, divisió, percentatge i esborrar.", "hi": "एक कैलकुलेटर बनाएँ जो जोड़, घटाव, गुणा, भाग, प्रतिशत और क्लियर का समर्थन करे।", "ko": "더하기, 빼기, 곱하기, 나누기, 백분율, 지우기를 지원하는 계산기를 만들어 주세요.", "ja": "足し算・引き算・掛け算・割り算、パーセント、クリアに対応した電卓を作ってください。", "it": "Crea una calcolatrice con addizione, sottrazione, moltiplicazione, divisione, percentuale e cancella."},
    },
    {
        "uuid": "00000000-0000-0000-0000-000000000004",
        "title": {"zh": "多页面 App 示例", "en": "Multi-page App example", "de": "Beispiel für eine mehrseitige App", "es": "Ejemplo de App multipágina", "fr": "Exemple d'App multipage", "pt": "Exemplo de App com várias páginas", "ca": "Exemple d'App de diverses pàgines", "hi": "मल्टी-पेज ऐप उदाहरण", "ko": "다중 페이지 앱 예제", "ja": "マルチページアプリの例", "it": "Esempio di App multipagina"},
        "prompt": {"zh": "做一个有 5 个页面、底部导航切换的多页面 App。", "en": "Build a multi-page App with 5 pages and bottom navigation to switch between them.", "de": "Baue eine mehrseitige App mit 5 Seiten und einer unteren Navigationsleiste zum Wechseln.", "es": "Haz una App multipágina con 5 páginas y navegación inferior para cambiar entre ellas.", "fr": "Crée une App multipage avec 5 pages et une navigation en bas pour basculer entre elles.", "pt": "Faça um App com 5 páginas e navegação inferior para alternar entre elas.", "ca": "Fes una App de diverses pàgines amb 5 pàgines i navegació inferior per canviar-hi.", "hi": "5 पेज और नीचे नेविगेशन से स्विच करने वाली एक मल्टी-पेज ऐप बनाएँ।", "ko": "페이지 5개와 하단 내비게이션으로 전환하는 다중 페이지 앱을 만들어 주세요.", "ja": "5つのページと下部ナビゲーションで切り替えるマルチページアプリを作ってください。", "it": "Crea un'App multipagina con 5 pagine e navigazione inferiore per passare tra loro."},
    },
    {
        "uuid": "00000000-0000-0000-0000-000000000005",
        "title": {"zh": "媒体播放", "en": "Media playback", "de": "Medienwiedergabe", "es": "Reproducción multimedia", "fr": "Lecture multimédia", "pt": "Reprodução de mídia", "ca": "Reproducció multimèdia", "hi": "मीडिया प्लेबैक", "ko": "미디어 재생", "ja": "メディア再生", "it": "Riproduzione multimediale"},
        "prompt": {"zh": "做一个媒体展示 App，能播放视频、展示图片。", "en": "Build a media showcase App that can play videos and display images.", "de": "Baue eine Medien-App, die Videos abspielen und Bilder anzeigen kann.", "es": "Haz una App de galería multimedia que reproduzca vídeos y muestre imágenes.", "fr": "Crée une App vitrine multimédia capable de lire des vidéos et d'afficher des images.", "pt": "Faça um App de galeria de mídia que reproduza vídeos e exiba imagens.", "ca": "Fes una App d'aparador multimèdia que reprodueixi vídeos i mostri imatges.", "hi": "एक मीडिया शोकेस ऐप बनाएँ जो वीडियो चला सके और चित्र दिखा सके।", "ko": "동영상을 재생하고 이미지를 표시할 수 있는 미디어 쇼케이스 앱을 만들어 주세요.", "ja": "動画を再生し、画像を表示できるメディア展示アプリを作ってください。", "it": "Crea un'App vetrina multimediale che riproduca video e mostri immagini."},
    },
    {
        "uuid": "00000000-0000-0000-0000-000000000006",
        "title": {"zh": "视频浏览", "en": "Video browsing", "de": "Video-Browsing", "es": "Exploración de vídeos", "fr": "Navigation vidéo", "pt": "Navegação de vídeos", "ca": "Exploració de vídeos", "hi": "वीडियो ब्राउज़िंग", "ko": "동영상 둘러보기", "ja": "動画ブラウジング", "it": "Sfoglia video"},
        "prompt": {"zh": "做一个视频浏览 App：列表 + 点进去播放。", "en": "Build a video browsing App: a list, and tap to play.", "de": "Baue eine Video-Browsing-App: eine Liste, zum Abspielen antippen.", "es": "Haz una App de exploración de vídeos: una lista y tocar para reproducir.", "fr": "Crée une App de navigation vidéo : une liste, et toucher pour lire.", "pt": "Faça um App de navegação de vídeos: uma lista e tocar para reproduzir.", "ca": "Fes una App d'exploració de vídeos: una llista i tocar per reproduir.", "hi": "एक वीडियो ब्राउज़िंग ऐप बनाएँ: एक सूची, और चलाने के लिए टैप करें।", "ko": "동영상 둘러보기 앱을 만들어 주세요: 목록에서 탭하면 재생.", "ja": "動画ブラウジングアプリを作ってください：一覧からタップで再生。", "it": "Crea un'App per sfogliare video: un elenco e tocca per riprodurre."},
    },
    {
        "uuid": "00000000-0000-0000-0000-000000000007",
        "title": {"zh": "拍照巡检", "en": "Photo inspection", "de": "Foto-Inspektion", "es": "Inspección con fotos", "fr": "Inspection photo", "pt": "Inspeção com fotos", "ca": "Inspecció amb fotos", "hi": "फ़ोटो निरीक्षण", "ko": "사진 점검", "ja": "写真点検", "it": "Ispezione con foto"},
        "prompt": {"zh": "做一个拍照巡检 App：拍照记录设备状态，生成巡检单。", "en": "Build a photo inspection App: take photos to record equipment status and generate an inspection report.", "de": "Baue eine Foto-Inspektions-App: Fotos aufnehmen, um den Gerätestatus zu erfassen, und einen Inspektionsbericht erstellen.", "es": "Haz una App de inspección con fotos: toma fotos para registrar el estado de los equipos y genera un parte de inspección.", "fr": "Crée une App d'inspection photo : prendre des photos pour consigner l'état des équipements et générer un rapport d'inspection.", "pt": "Faça um App de inspeção com fotos: tire fotos para registrar o estado dos equipamentos e gere um relatório de inspeção.", "ca": "Fes una App d'inspecció amb fotos: fer fotos per registrar l'estat dels equips i generar un informe d'inspecció.", "hi": "एक फ़ोटो निरीक्षण ऐप बनाएँ: उपकरण की स्थिति दर्ज करने के लिए फ़ोटो लें और एक निरीक्षण रिपोर्ट बनाएँ।", "ko": "사진 점검 앱을 만들어 주세요: 사진을 찍어 장비 상태를 기록하고 점검표를 생성합니다.", "ja": "写真点検アプリを作ってください：写真を撮って設備の状態を記録し、点検票を生成します。", "it": "Crea un'App di ispezione con foto: scatta foto per registrare lo stato delle apparecchiature e genera un rapporto di ispezione."},
    },
    {
        "uuid": "00000000-0000-0000-0000-000000000008",
        "title": {"zh": "课程播放器", "en": "Course player", "de": "Kurs-Player", "es": "Reproductor de cursos", "fr": "Lecteur de cours", "pt": "Reprodutor de cursos", "ca": "Reproductor de cursos", "hi": "कोर्स प्लेयर", "ko": "강좌 플레이어", "ja": "コースプレーヤー", "it": "Lettore di corsi"},
        "prompt": {"zh": "做一个在线课程播放器：章节列表 + 视频播放 + 学习进度。", "en": "Build an online course player: a chapter list, video playback, and learning progress.", "de": "Baue einen Online-Kurs-Player: Kapitelliste, Videowiedergabe und Lernfortschritt.", "es": "Haz un reproductor de cursos en línea: lista de capítulos, reproducción de vídeo y progreso de aprendizaje.", "fr": "Crée un lecteur de cours en ligne : liste des chapitres, lecture vidéo et progression d'apprentissage.", "pt": "Faça um reprodutor de cursos on-line: lista de capítulos, reprodução de vídeo e progresso de aprendizagem.", "ca": "Fes un reproductor de cursos en línia: llista de capítols, reproducció de vídeo i progrés d'aprenentatge.", "hi": "एक ऑनलाइन कोर्स प्लेयर बनाएँ: अध्याय सूची, वीडियो प्लेबैक और सीखने की प्रगति।", "ko": "온라인 강좌 플레이어를 만들어 주세요: 챕터 목록, 동영상 재생, 학습 진도.", "ja": "オンラインコースプレーヤーを作ってください：チャプター一覧、動画再生、学習進捗。", "it": "Crea un lettore di corsi online: elenco dei capitoli, riproduzione video e progressi di apprendimento."},
    },
    {
        "uuid": "00000000-0000-0000-0000-000000000009",
        "title": {"zh": "运维数据看板", "en": "Ops data dashboard", "de": "Ops-Daten-Dashboard", "es": "Panel de datos de operaciones", "fr": "Tableau de bord des données d'exploitation", "pt": "Painel de dados de operações", "ca": "Tauler de dades d'operacions", "hi": "ऑप्स डेटा डैशबोर्ड", "ko": "운영 데이터 대시보드", "ja": "運用データダッシュボード", "it": "Dashboard dati operativi"},
        "prompt": {"zh": "做一个运维数据仪表盘：服务状态、指标图表、告警列表。", "en": "Build an ops dashboard: service status, metric charts, and an alert list.", "de": "Baue ein Ops-Dashboard: Service-Status, Metrik-Diagramme und eine Alarmliste.", "es": "Haz un panel de operaciones: estado de servicios, gráficos de métricas y lista de alertas.", "fr": "Crée un tableau de bord d'exploitation : état des services, graphiques de métriques et liste d'alertes.", "pt": "Faça um painel de operações: status dos serviços, gráficos de métricas e lista de alertas.", "ca": "Fes un tauler d'operacions: estat dels serveis, gràfics de mètriques i llista d'alertes.", "hi": "एक ऑप्स डैशबोर्ड बनाएँ: सेवा स्थिति, मीट्रिक चार्ट और अलर्ट सूची।", "ko": "운영 대시보드를 만들어 주세요: 서비스 상태, 지표 차트, 알림 목록.", "ja": "運用ダッシュボードを作ってください：サービス状態、メトリクスのグラフ、アラート一覧。", "it": "Crea una dashboard operativa: stato dei servizi, grafici delle metriche ed elenco degli avvisi."},
    },
    {
        "uuid": "00000000-0000-0000-0000-000000000010",
        "title": {"zh": "智能家居", "en": "Smart home", "de": "Smart Home", "es": "Hogar inteligente", "fr": "Maison connectée", "pt": "Casa inteligente", "ca": "Llar intel·ligent", "hi": "स्मार्ट होम", "ko": "스마트홈", "ja": "スマートホーム", "it": "Casa intelligente"},
        "prompt": {"zh": "做一个智能家居控制面板：灯光、空调、场景一键控制。", "en": "Build a smart home control panel: one-tap control of lights, air conditioning, and scenes.", "de": "Baue ein Smart-Home-Bedienfeld: Ein-Tipp-Steuerung von Licht, Klimaanlage und Szenen.", "es": "Haz un panel de control de hogar inteligente: control con un toque de luces, aire acondicionado y escenas.", "fr": "Crée un panneau de contrôle de maison connectée : contrôle en un toucher des lumières, de la climatisation et des scènes.", "pt": "Faça um painel de controle de casa inteligente: controle com um toque de luzes, ar-condicionado e cenas.", "ca": "Fes un tauler de control de llar intel·ligent: control amb un toc de llums, aire condicionat i escenes.", "hi": "एक स्मार्ट होम कंट्रोल पैनल बनाएँ: रोशनी, एयर कंडीशनर और सीन का वन-टैप नियंत्रण।", "ko": "스마트홈 제어판을 만들어 주세요: 조명, 에어컨, 장면을 원터치로 제어.", "ja": "スマートホームのコントロールパネルを作ってください：照明・エアコン・シーンをワンタップで操作。", "it": "Crea un pannello di controllo per la casa intelligente: controllo con un tocco di luci, climatizzatore e scene."},
    },
    {
        "uuid": "00000000-0000-0000-0000-000000000011",
        "title": {"zh": "旅行通行证", "en": "Travel pass", "de": "Reise-Pass", "es": "Pase de viaje", "fr": "Pass de voyage", "pt": "Passe de viagem", "ca": "Passi de viatge", "hi": "यात्रा पास", "ko": "여행 패스", "ja": "トラベルパス", "it": "Pass di viaggio"},
        "prompt": {"zh": "做一个旅行通行证 App：行程卡片、二维码、登机信息。", "en": "Build a travel pass App: itinerary cards, QR codes, and boarding info.", "de": "Baue eine Reise-Pass-App: Reiseplan-Karten, QR-Codes und Boarding-Informationen.", "es": "Haz una App de pase de viaje: tarjetas de itinerario, códigos QR e información de embarque.", "fr": "Crée une App de pass de voyage : cartes d'itinéraire, codes QR et informations d'embarquement.", "pt": "Faça um App de passe de viagem: cartões de itinerário, códigos QR e informações de embarque.", "ca": "Fes una App de passi de viatge: targetes d'itinerari, codis QR i informació d'embarcament.", "hi": "एक यात्रा पास ऐप बनाएँ: यात्रा कार्ड, QR कोड और बोर्डिंग जानकारी।", "ko": "여행 패스 앱을 만들어 주세요: 일정 카드, QR 코드, 탑승 정보.", "ja": "トラベルパスアプリを作ってください：旅程カード、QRコード、搭乗情報。", "it": "Crea un'App di pass di viaggio: schede di itinerario, codici QR e informazioni di imbarco."},
    },
    {
        "uuid": "00000000-0000-0000-0000-000000000012",
        "title": {"zh": "像素三消游戏", "en": "Pixel match-3 game", "de": "Pixel-Match-3-Spiel", "es": "Juego match-3 estilo píxel", "fr": "Jeu de match-3 pixel art", "pt": "Jogo match-3 em pixel art", "ca": "Joc match-3 estil píxel", "hi": "पिक्सेल मैच-3 गेम", "ko": "픽셀 매치-3 게임", "ja": "ピクセル風マッチ3ゲーム", "it": "Gioco match-3 in stile pixel"},
        "prompt": {"zh": "做一个像素风格的三消小游戏。", "en": "Build a pixel-art match-3 mini-game.", "de": "Baue ein Match-3-Minispiel im Pixel-Look.", "es": "Haz un minijuego match-3 con estilo pixelado.", "fr": "Crée un mini-jeu de match-3 en pixel art.", "pt": "Faça um minijogo match-3 em pixel art.", "ca": "Fes un minijoc match-3 amb estil píxel.", "hi": "एक पिक्सेल-शैली का मैच-3 मिनी गेम बनाएँ।", "ko": "픽셀 스타일의 매치-3 미니게임을 만들어 주세요.", "ja": "ピクセル風のマッチ3ミニゲームを作ってください。", "it": "Crea un minigioco match-3 in stile pixel."},
    },
    {
        "uuid": "00000000-0000-0000-0000-000000000013",
        "title": {"zh": "记账预算", "en": "Budget & expenses", "de": "Haushaltsbuch & Budget", "es": "Gastos y presupuesto", "fr": "Comptes & budget", "pt": "Contas e orçamento", "ca": "Comptes i pressupost", "hi": "बजट और खर्च", "ko": "가계부·예산", "ja": "家計簿・予算", "it": "Spese e budget"},
        "prompt": {"zh": "做一个记账 App：收支记录、分类统计、月度预算。", "en": "Build an expense-tracking App: record income and spending, category stats, and a monthly budget.", "de": "Baue eine Haushaltsbuch-App: Einnahmen und Ausgaben erfassen, Auswertung nach Kategorien und ein Monatsbudget.", "es": "Haz una App de gastos: registro de ingresos y gastos, estadísticas por categoría y presupuesto mensual.", "fr": "Crée une App de gestion de dépenses : suivi des revenus et dépenses, statistiques par catégorie et budget mensuel.", "pt": "Faça um App de finanças: registro de receitas e despesas, estatísticas por categoria e orçamento mensal.", "ca": "Fes una App de comptes: registre d'ingressos i despeses, estadístiques per categoria i pressupost mensual.", "hi": "एक खर्च-ट्रैकिंग ऐप बनाएँ: आय-व्यय रिकॉर्ड, श्रेणी आँकड़े और मासिक बजट।", "ko": "가계부 앱을 만들어 주세요: 수입·지출 기록, 카테고리별 통계, 월별 예산.", "ja": "家計簿アプリを作ってください：収支の記録、カテゴリ別集計、月間予算。", "it": "Crea un'App per le spese: registro di entrate e uscite, statistiche per categoria e budget mensile."},
    },
    {
        "uuid": "00000000-0000-0000-0000-000000000014",
        "title": {"zh": "客户管理 CRM", "en": "Customer management (CRM)", "de": "Kundenverwaltung (CRM)", "es": "Gestión de clientes (CRM)", "fr": "Gestion des clients (CRM)", "pt": "Gestão de clientes (CRM)", "ca": "Gestió de clients (CRM)", "hi": "ग्राहक प्रबंधन (CRM)", "ko": "고객 관리 (CRM)", "ja": "顧客管理（CRM）", "it": "Gestione clienti (CRM)"},
        "prompt": {"zh": "做一个轻量 CRM：客户列表、跟进记录、状态标签。", "en": "Build a lightweight CRM: a customer list, follow-up records, and status labels.", "de": "Baue ein schlankes CRM: Kundenliste, Follow-up-Einträge und Status-Labels.", "es": "Haz un CRM ligero: lista de clientes, registros de seguimiento y etiquetas de estado.", "fr": "Crée un CRM léger : liste de clients, historique de suivi et étiquettes de statut.", "pt": "Faça um CRM leve: lista de clientes, registros de acompanhamento e etiquetas de status.", "ca": "Fes un CRM lleuger: llista de clients, registres de seguiment i etiquetes d'estat.", "hi": "एक हल्का CRM बनाएँ: ग्राहक सूची, फ़ॉलो-अप रिकॉर्ड और स्थिति लेबल।", "ko": "가벼운 CRM을 만들어 주세요: 고객 목록, 후속 기록, 상태 라벨.", "ja": "軽量なCRMを作ってください：顧客リスト、フォローアップ記録、ステータスラベル。", "it": "Crea un CRM leggero: elenco clienti, note di follow-up ed etichette di stato."},
    },
    {
        "uuid": "00000000-0000-0000-0000-000000000015",
        "title": {"zh": "习惯打卡", "en": "Habit tracker", "de": "Gewohnheits-Tracker", "es": "Seguimiento de hábitos", "fr": "Suivi d'habitudes", "pt": "Rastreador de hábitos", "ca": "Seguiment d'hàbits", "hi": "आदत ट्रैकर", "ko": "습관 체크", "ja": "習慣トラッカー", "it": "Tracker delle abitudini"},
        "prompt": {"zh": "做一个习惯打卡 App：每日打卡、连续天数、热力图。", "en": "Build a habit tracker App: daily check-ins, streak counts, and a heatmap.", "de": "Baue eine Gewohnheits-Tracker-App: tägliches Einchecken, Serien-Zähler und eine Heatmap.", "es": "Haz una App de seguimiento de hábitos: registro diario, racha de días y mapa de calor.", "fr": "Crée une App de suivi d'habitudes : pointage quotidien, nombre de jours d'affilée et carte de chaleur.", "pt": "Faça um App de hábitos: registro diário, sequência de dias e mapa de calor.", "ca": "Fes una App de seguiment d'hàbits: registre diari, ratxa de dies i mapa de calor.", "hi": "एक आदत ट्रैकर ऐप बनाएँ: दैनिक चेक-इन, लगातार दिनों की गिनती और हीटमैप।", "ko": "습관 체크 앱을 만들어 주세요: 매일 체크인, 연속 일수, 히트맵.", "ja": "習慣トラッカーアプリを作ってください：毎日のチェックイン、連続日数、ヒートマップ。", "it": "Crea un'App per le abitudini: check-in giornaliero, giorni consecutivi e mappa di calore."},
    },
    {
        "uuid": "00000000-0000-0000-0000-000000000016",
        "title": {"zh": "笔记", "en": "Notes", "de": "Notizen", "es": "Notas", "fr": "Notes", "pt": "Notas", "ca": "Notes", "hi": "नोट्स", "ko": "메모", "ja": "メモ", "it": "Note"},
        "prompt": {"zh": "做一个笔记 App：新建、编辑、列表、搜索。", "en": "Build a notes App: create, edit, list, and search.", "de": "Baue eine Notizen-App: erstellen, bearbeiten, auflisten und suchen.", "es": "Haz una App de notas: crear, editar, listar y buscar.", "fr": "Crée une App de notes : créer, modifier, lister et rechercher.", "pt": "Faça um App de notas: criar, editar, listar e pesquisar.", "ca": "Fes una App de notes: crear, editar, llistar i cercar.", "hi": "एक नोट्स ऐप बनाएँ: नया बनाएँ, संपादित करें, सूची और खोज।", "ko": "메모 앱을 만들어 주세요: 새로 만들기, 편집, 목록, 검색.", "ja": "メモアプリを作ってください：新規作成、編集、一覧、検索。", "it": "Crea un'App di note: crea, modifica, elenca e cerca."},
    },
    {
        "uuid": "00000000-0000-0000-0000-000000000017",
        "title": {"zh": "健身训练", "en": "Workout training", "de": "Fitness-Training", "es": "Entrenamiento fitness", "fr": "Entraînement fitness", "pt": "Treino fitness", "ca": "Entrenament fitness", "hi": "वर्कआउट ट्रेनिंग", "ko": "운동 트레이닝", "ja": "フィットネストレーニング", "it": "Allenamento fitness"},
        "prompt": {"zh": "做一个健身训练 App：训练计划、动作计时、记录。", "en": "Build a workout App: training plans, exercise timers, and records.", "de": "Baue eine Fitness-App: Trainingspläne, Übungs-Timer und Aufzeichnungen.", "es": "Haz una App de entrenamiento: planes de entrenamiento, temporizador de ejercicios y registros.", "fr": "Crée une App d'entraînement : plans d'entraînement, minuteur d'exercices et historique.", "pt": "Faça um App de treino: planos de treino, cronômetro de exercícios e registros.", "ca": "Fes una App d'entrenament: plans d'entrenament, temporitzador d'exercicis i registres.", "hi": "एक वर्कआउट ऐप बनाएँ: प्रशिक्षण योजना, व्यायाम टाइमर और रिकॉर्ड।", "ko": "운동 앱을 만들어 주세요: 운동 계획, 동작 타이머, 기록.", "ja": "フィットネスアプリを作ってください：トレーニング計画、種目のタイマー、記録。", "it": "Crea un'App di allenamento: piani di allenamento, timer degli esercizi e registri."},
    },
    {
        "uuid": "00000000-0000-0000-0000-000000000018",
        "title": {"zh": "超级 App 首页", "en": "Super app home", "de": "Super-App-Startseite", "es": "Inicio de superapp", "fr": "Accueil de super-app", "pt": "Início de superapp", "ca": "Inici de superapp", "hi": "सुपर ऐप होम", "ko": "슈퍼앱 홈", "ja": "スーパーアプリのホーム", "it": "Home della super app"},
        "prompt": {"zh": "做一个超级 App 首页：多功能入口聚合、轮播、九宫格。", "en": "Build a super-app home screen: an aggregated hub of feature entries, a carousel, and a grid of icons.", "de": "Baue eine Super-App-Startseite: gebündelte Funktionseinstiege, ein Karussell und ein Icon-Raster.", "es": "Haz la pantalla de inicio de una superapp: un hub con accesos a varias funciones, un carrusel y una cuadrícula de iconos.", "fr": "Crée l'écran d'accueil d'une super-app : un hub d'accès aux fonctionnalités, un carrousel et une grille d'icônes.", "pt": "Faça a tela inicial de uma superapp: um hub com atalhos de funções, um carrossel e uma grade de ícones.", "ca": "Fes la pantalla d'inici d'una superapp: un hub amb accessos a funcions, un carrusel i una graella d'icones.", "hi": "एक सुपर ऐप होम स्क्रीन बनाएँ: विभिन्न फ़ीचर प्रवेश-बिंदुओं का हब, कैरोसेल और आइकन ग्रिड।", "ko": "슈퍼앱 홈 화면을 만들어 주세요: 여러 기능 진입점 허브, 캐러셀, 아이콘 그리드.", "ja": "スーパーアプリのホーム画面を作ってください：多機能への入口を集約、カルーセル、アイコンのグリッド。", "it": "Crea la schermata home di una super app: un hub con gli accessi alle funzioni, un carosello e una griglia di icone."},
    },
    {
        "uuid": "00000000-0000-0000-0000-000000000019",
        "title": {"zh": "文本收集器", "en": "Text collector", "de": "Text-Sammler", "es": "Recopilador de texto", "fr": "Collecteur de texte", "pt": "Coletor de texto", "ca": "Recopilador de text", "hi": "टेक्स्ट कलेक्टर", "ko": "텍스트 수집기", "ja": "テキストコレクター", "it": "Raccoglitore di testo"},
        "prompt": {"zh": "做一个文本收集器：快速记录、列表管理、复制。", "en": "Build a text collector: quick capture, list management, and copy.", "de": "Baue einen Text-Sammler: schnelles Erfassen, Listenverwaltung und Kopieren.", "es": "Haz un recopilador de texto: captura rápida, gestión de listas y copiar.", "fr": "Crée un collecteur de texte : saisie rapide, gestion de listes et copie.", "pt": "Faça um coletor de texto: captura rápida, gestão de listas e copiar.", "ca": "Fes un recopilador de text: captura ràpida, gestió de llistes i copiar.", "hi": "एक टेक्स्ट कलेक्टर बनाएँ: त्वरित रिकॉर्ड, सूची प्रबंधन और कॉपी।", "ko": "텍스트 수집기를 만들어 주세요: 빠른 기록, 목록 관리, 복사.", "ja": "テキストコレクターを作ってください：素早く記録、一覧管理、コピー。", "it": "Crea un raccoglitore di testo: acquisizione rapida, gestione dell'elenco e copia."},
    },
    {
        "uuid": "00000000-0000-0000-0000-000000000020",
        "title": {"zh": "2048 数字游戏", "en": "2048 number game", "de": "2048 Zahlenspiel", "es": "Juego de números 2048", "fr": "Jeu de nombres 2048", "pt": "Jogo de números 2048", "ca": "Joc de números 2048", "hi": "2048 नंबर गेम", "ko": "2048 숫자 게임", "ja": "2048 数字ゲーム", "it": "Gioco di numeri 2048"},
        "prompt": {"zh": "做一个 2048 数字合并游戏。", "en": "Build a 2048 number-merging game.", "de": "Baue ein 2048-Zahlen-Merge-Spiel.", "es": "Haz un juego de combinar números 2048.", "fr": "Crée un jeu de fusion de nombres 2048.", "pt": "Faça um jogo de combinar números 2048.", "ca": "Fes un joc de combinar números 2048.", "hi": "एक 2048 नंबर मर्ज गेम बनाएँ।", "ko": "2048 숫자 합치기 게임을 만들어 주세요.", "ja": "2048の数字合成ゲームを作ってください。", "it": "Crea un gioco di combinazione di numeri 2048."},
    },
    {
        "uuid": "00000000-0000-0000-0000-000000000021",
        "title": {"zh": "贪吃蛇", "en": "Snake", "de": "Snake", "es": "Snake (la serpiente)", "fr": "Snake (le serpent)", "pt": "Snake (a cobrinha)", "ca": "Snake (la serp)", "hi": "स्नेक गेम", "ko": "스네이크", "ja": "スネークゲーム", "it": "Snake (il serpente)"},
        "prompt": {"zh": "做一个贪吃蛇小游戏：吃食物变长、撞墙结束。", "en": "Build a Snake mini-game: eat food to grow longer, game over on hitting a wall.", "de": "Baue ein Snake-Minispiel: Futter fressen, um länger zu werden, Spielende beim Aufprall auf die Wand.", "es": "Haz un minijuego de Snake: come para crecer y termina al chocar con la pared.", "fr": "Crée un mini-jeu Snake : mange pour grandir, fin de partie en heurtant un mur.", "pt": "Faça um minijogo de Snake: coma para crescer e o jogo acaba ao bater na parede.", "ca": "Fes un minijoc de Snake: menja per créixer i s'acaba en xocar amb la paret.", "hi": "एक स्नेक मिनी गेम बनाएँ: खाना खाकर लंबा हो, दीवार से टकराने पर खत्म।", "ko": "스네이크 미니게임을 만들어 주세요: 먹이를 먹으면 길어지고, 벽에 부딪히면 종료.", "ja": "スネークのミニゲームを作ってください：エサを食べて長くなり、壁にぶつかると終了。", "it": "Crea un minigioco di Snake: mangia per allungarti, partita finita se colpisci il muro."},
    },
    {
        "uuid": "00000000-0000-0000-0000-000000000022",
        "title": {"zh": "Flappy Bird", "en": "Flappy Bird", "de": "Flappy Bird", "es": "Flappy Bird", "fr": "Flappy Bird", "pt": "Flappy Bird", "ca": "Flappy Bird", "hi": "Flappy Bird", "ko": "Flappy Bird", "ja": "Flappy Bird", "it": "Flappy Bird"},
        "prompt": {"zh": "做一个 Flappy Bird 点击飞行小游戏。", "en": "Build a Flappy Bird tap-to-fly mini-game.", "de": "Baue ein Flappy-Bird-Minispiel mit Tippen zum Fliegen.", "es": "Haz un minijuego tipo Flappy Bird: toca para volar.", "fr": "Crée un mini-jeu Flappy Bird : touche pour voler.", "pt": "Faça um minijogo Flappy Bird: toque para voar.", "ca": "Fes un minijoc Flappy Bird: toca per volar.", "hi": "एक Flappy Bird टैप-टू-फ्लाई मिनी गेम बनाएँ।", "ko": "탭하여 나는 Flappy Bird 미니게임을 만들어 주세요.", "ja": "タップで飛ぶFlappy Birdのミニゲームを作ってください。", "it": "Crea un minigioco Flappy Bird: tocca per volare."},
    },
    {
        "uuid": "00000000-0000-0000-0000-000000000023",
        "title": {"zh": "广场社区 · 全栈论坛（板块 / 楼中楼 / 好友私信）", "en": "Plaza Community · full-stack forum (boards / nested replies / friend DMs)", "de": "Plaza-Community · Full-Stack-Forum (Boards / verschachtelte Antworten / Freund-DMs)", "es": "Comunidad Plaza · foro full-stack (tablones / respuestas anidadas / MD entre amigos)", "fr": "Communauté Plaza · forum full-stack (forums / réponses imbriquées / MP entre amis)", "pt": "Comunidade Plaza · fórum full-stack (áreas / respostas aninhadas / DMs entre amigos)", "ca": "Comunitat Plaza · fòrum full-stack (taulers / respostes imbricades / MD entre amics)", "hi": "प्लाज़ा कम्युनिटी · फ़ुल-स्टैक फ़ोरम (बोर्ड / नेस्टेड रिप्लाई / मित्र निजी संदेश)", "ko": "광장 커뮤니티 · 풀스택 포럼 (게시판 / 중첩 답글 / 친구 쪽지)", "ja": "広場コミュニティ・フルスタック掲示板（板／入れ子の返信／友だちDM）", "it": "Comunità Plaza · forum full-stack (bacheche / risposte annidate / DM tra amici)"},
        "prompt": {"zh": "做一个类似贴吧的全栈论坛 App：板块分区、发主题帖、楼中楼盖楼回帖、用户昵称主页、加好友、好友间私信，要有真实后端能保存数据。", "en": "Build a message-board-style full-stack forum App: board sections, topic posts, nested threaded replies, user profile pages, adding friends, and private messaging between friends — with a real backend that persists data.", "de": "Baue eine Full-Stack-Forum-App im Message-Board-Stil: Board-Bereiche, Themen-Beiträge, verschachtelte Antwort-Threads, Benutzerprofilseiten, Freunde hinzufügen und private Nachrichten zwischen Freunden – mit einem echten Backend, das Daten speichert.", "es": "Haz una App de foro full-stack tipo tablón de mensajes: secciones de tablones, publicaciones de temas, respuestas anidadas en hilo, páginas de perfil de usuario, añadir amigos y mensajes privados entre amigos, con un backend real que guarde los datos.", "fr": "Crée une App de forum full-stack de type babillard : sections de forums, sujets de discussion, réponses imbriquées en fil, pages de profil utilisateur, ajout d'amis et messages privés entre amis, avec un vrai backend qui enregistre les données.", "pt": "Faça um App de fórum full-stack estilo quadro de mensagens: seções de áreas, tópicos, respostas aninhadas em thread, páginas de perfil de usuário, adicionar amigos e mensagens privadas entre amigos, com um backend real que salve os dados.", "ca": "Fes una App de fòrum full-stack tipus tauler de missatges: seccions de taulers, publicacions de temes, respostes imbricades en fil, pàgines de perfil d'usuari, afegir amics i missatges privats entre amics, amb un backend real que desi les dades.", "hi": "मैसेज-बोर्ड जैसी एक फ़ुल-स्टैक फ़ोरम ऐप बनाएँ: बोर्ड सेक्शन, विषय पोस्ट, नेस्टेड थ्रेडेड रिप्लाई, उपयोगकर्ता प्रोफ़ाइल पेज, मित्र जोड़ना और मित्रों के बीच निजी संदेश — डेटा सहेजने वाले असली बैकएंड के साथ।", "ko": "게시판형 풀스택 포럼 앱을 만들어 주세요: 게시판 구획, 주제 글, 중첩된 스레드 답글, 사용자 프로필 페이지, 친구 추가, 친구 간 개인 메시지 — 데이터를 저장하는 실제 백엔드 포함.", "ja": "掲示板型のフルスタック掲示板アプリを作ってください：板の区分け、スレッド投稿、入れ子のスレッド返信、ユーザーのプロフィールページ、友だち追加、友だち同士のダイレクトメッセージ。データを保存できる本物のバックエンド付きで。", "it": "Crea un'App di forum full-stack in stile bacheca: sezioni di bacheche, post di argomenti, risposte annidate in thread, pagine profilo utente, aggiunta di amici e messaggi privati tra amici, con un backend reale che salva i dati."},
    },
]


def demo_prompt_list(lang=None) -> list:
    """服务端下发的 demo 选择目录（uuid/title/prompt），按 `lang` 返回对应语言文案。
    客户端拉取它渲染选择列表；加一个 demo 只改后端（这里 + DEMO_SESSIONS + 录制文件），不用客户端发版。
    只返回有回放映射(DEMO_SESSIONS)的项，避免目录与回放漂移。
    title/prompt 兼容纯字符串与多语言 map（缺译优雅回退，见 `_pick_lang`）。"""
    code = _lang_code(lang)
    out = []
    for p in DEMO_PROMPTS:
        if p.get("uuid") not in DEMO_SESSIONS:
            continue
        out.append({
            "uuid": p["uuid"],
            "title": _pick_lang(p.get("title", ""), code),
            "prompt": _pick_lang(p.get("prompt", ""), code),
        })
    return out

# 每条事件之间的 sleep。客户端已有打字机缓冲做平滑，这里放慢事件投递节奏更像真实生成
# 的「分段产出」。可用环境变量覆盖。
_REPLAY_SLEEP = float(os.environ.get("AI_DEMO_REPLAY_SLEEP", "0.90"))

DEMO_PROVIDER = "demo"

# Demo 专用对象存储桶：所有 demo 的 app.json 预先固定上传到这里（public-read），
# 回放时直接返回固定公共 URL，不再每次临时上传/预签名 → 更快、链接稳定不过期。
# 桶的创建/上传由 myapp-ctl 部署后步骤负责（集群初始化的一部分），见 scripts/myapp_ctl/。
DEMO_BUCKET = os.environ.get("AI_DEMO_BUCKET", "demo")


def is_demo_uuid(session_id) -> bool:
    return isinstance(session_id, str) and session_id in DEMO_SESSIONS


def _path(base: str, ext: str) -> str:
    return os.path.join(REPLAY_DIR, f"{base}.{ext}")


# demo 支持的 11 种语言（与框架 i18n 一致）。回放叙事/提示词按语言下发；app.json 不在此列——
# 它走 DSL 原生 i18n（global.i18n + {{ t() }}），由框架按用户 locale 自动渲染，一份即可。
_DEMO_LANGS = ("zh", "en", "de", "es", "fr", "pt", "ca", "hi", "ko", "ja", "it")


def _lang_code(lang) -> str:
    """归一化语言到 demo 支持的 2 字母码（zh-CN→zh），不识别则回退 zh。"""
    if not lang:
        return "zh"
    code = str(lang).split("-")[0].split("_")[0].strip().lower()
    return code if code in _DEMO_LANGS else "zh"


def _pick_lang(value, code: str):
    """title/prompt 兼容纯字符串(旧)与 {lang: str} 多语言 map；按 code→en→zh→任意 回退。"""
    if isinstance(value, dict):
        return value.get(code) or value.get("en") or value.get("zh") or next(iter(value.values()), "")
    return value


def _resolve_jsonl(base: str, lang=None) -> str:
    """选录制文件：非 zh 且存在 `<base>.<lang>.jsonl` 用它；否则回退原 `<base>.jsonl`(zh)。
    这样部分语言没翻译时优雅降级到中文，而不是回放失败。"""
    code = _lang_code(lang)
    if code != "zh":
        p = _path(base, f"{code}.jsonl")
        if os.path.exists(p):
            return p
    return _path(base, "jsonl")


def start(session_id: str, user_id: str, lang=None):
    """在 chat_start 里被调用：建 meta（标记 provider=demo 供 SSE 僵尸检测豁免），
    起一个后台线程回放 jsonl（按 `lang` 选对应语言的录制），立即返回与正常 chat_start 同形状的响应。"""
    base = DEMO_SESSIONS[session_id]
    store = ai_session.SessionStore()
    # create_meta 会清掉旧 stream/meta → 重复点同一个 demo 是幂等的
    store.create_meta(
        session_id,
        user_id=user_id,
        provider=DEMO_PROVIDER,
        agent=DEMO_PROVIDER,
        quota_used=0,
        quota_limit=0,
        quota_remaining=0,
        status=ai_session.STATUS_RUNNING,  # 非 QUEUED，避免 SSE 反复发 queue 状态
    )
    ai_session._executor.submit(_replay_worker, session_id, base, _lang_code(lang))
    logger.info("[DEMO] replay started sid=%s base=%s lang=%s user=%s", session_id, base, _lang_code(lang), user_id)
    return jsonify({
        "session_id": session_id,
        "status": "running",
        "resumed": False,
        "agent": DEMO_PROVIDER,
        "agent_scope": "public",
        "generation_pipeline": "demo_replay",
        "queue_position": 0,
    })


def _minio_client():
    from minio import Minio
    return Minio(
        ai_session.MINIO_ENDPOINT,
        access_key=ai_session.MINIO_ACCESS_KEY,
        secret_key=ai_session.MINIO_SECRET_KEY,
        secure=ai_session.MINIO_SECURE,
    )


def _demo_public_policy() -> dict:
    return {
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Principal": {"AWS": ["*"]},
            "Action": ["s3:GetObject"],
            "Resource": [f"arn:aws:s3:::{DEMO_BUCKET}/*"],
        }],
    }


def ensure_demo_assets(force: bool = False) -> dict:
    """确保 demo 桶存在、public-read，并把每个 <base>.app.json 固定上传成 <base>.json。
    幂等：内容未变（按 size+md5/etag 比对）则跳过上传。返回 {base: 是否本次上传}。
    后端启动后由 myapp-ctl 部署步骤调用（集群初始化的一部分），首个回放也会兜底调用。
    MinIO 不可用时抛异常，由调用方决定降级。"""
    import hashlib
    import io
    import json as _json

    if not ai_session.MINIO_ACCESS_KEY or not ai_session.MINIO_SECRET_KEY:
        raise RuntimeError("backend MinIO credentials are not configured")

    client = _minio_client()
    if not client.bucket_exists(DEMO_BUCKET):
        client.make_bucket(DEMO_BUCKET)
    try:
        client.set_bucket_policy(DEMO_BUCKET, _json.dumps(_demo_public_policy()))
    except Exception as e:  # 策略设置失败不致命（桶可能已是 public）
        logger.warning("[DEMO] set public policy failed bucket=%s: %s", DEMO_BUCKET, e)

    result = {}
    for base in sorted(set(DEMO_SESSIONS.values())):
        app_path = _path(base, "app.json")
        if not os.path.exists(app_path):
            continue  # 纯前端内嵌 demo 无随包 app.json
        with open(app_path, "rb") as f:
            data = f.read()
        key = f"{base}.json"
        need = True
        if not force:
            try:
                st = client.stat_object(DEMO_BUCKET, key)
                if st.size == len(data) and (st.etag or "").strip('"') == hashlib.md5(data).hexdigest():
                    need = False  # 内容未变 → 跳过
            except Exception:
                need = True
        if need:
            client.put_object(
                DEMO_BUCKET, key, io.BytesIO(data), len(data),
                content_type="application/json",
            )
        result[base] = need
    logger.info("[DEMO] assets ensured bucket=%s uploaded=%d/%d",
                DEMO_BUCKET, sum(1 for v in result.values() if v), len(result))
    return result


def _demo_public_url(base: str) -> str:
    """固定公共 URL（demo 桶 public-read，path-style 直取，无需预签名）。"""
    return f"{ai_session.MINIO_PUBLIC_URL.rstrip('/')}/{DEMO_BUCKET}/{base}.json"


# None=未探测；True=demo 桶就绪用固定 URL；False=不可用，降级到旧的临时预签名上传
_assets_ready = None


def _resolve_app_url(base: str):
    """回放交付链接：优先固定公共 URL（不每次上传）；demo 桶不可用时降级回临时上传。
    没有随包 app.json（纯前端内嵌）→ 返回 None，沿用录制里的原链接。"""
    if not os.path.exists(_path(base, "app.json")):
        return None
    global _assets_ready
    if _assets_ready is None:
        try:
            ensure_demo_assets()
            _assets_ready = True
        except Exception as e:
            logger.warning("[DEMO] ensure_demo_assets unavailable, fall back to temp upload: %s", e)
            _assets_ready = False
    if _assets_ready:
        return _demo_public_url(base)
    return _mint_fresh_url(base)


def _mint_fresh_url(base: str):
    """把随包的 app.json 重新上传，拿一个新的 24h presigned URL（避免录制时的链接过期）。
    没有 app.json（如纯前端 demo 已把完整 JSON 内嵌在事件里）或上传失败 → 返回 None，沿用录制里的链接。"""
    app_path = _path(base, "app.json")
    if not os.path.exists(app_path):
        return None
    try:
        with open(app_path, "rb") as f:
            return ai_session._upload_temp_json_app(f.read())
    except Exception as e:  # MinIO 不可用（如本机）等 → 退回录制链接
        logger.warning("[DEMO] mint fresh url failed base=%s: %s", base, e)
        return None


def _rewrite_event_url(ev: dict, fresh: str) -> dict:
    if not fresh or not isinstance(ev, dict):
        return ev
    ca = ev.get("client_action")
    if isinstance(ca, dict) and ca.get("type") == "json_app_ready":
        ev = dict(ev)
        ca = dict(ca)
        ca["url"] = fresh
        ev["client_action"] = ca
    return ev


def _rewrite_actions_url(actions, fresh: str):
    if not fresh or not isinstance(actions, list):
        return actions
    out = []
    replaced = False
    for a in actions:
        if isinstance(a, dict) and a.get("type") == "json_app_ready":
            a = dict(a)
            a["url"] = fresh
            replaced = True
        out.append(a)
    if not replaced:
        out.append({"type": "json_app_ready", "url": fresh})
    return out


def _wake_sse(store, session_id: str):
    """唤醒可能阻塞在 xread 上的 SSE 连接。

    set_status 只更新 meta（HSET），不往 stream 写事件；而 SSE handler 此刻多半正阻塞在
    `xread BLOCK` 上等新事件——状态变更不会让它返回（实测 eventlet 下 block 超时也迟迟不触发，
    回放线程结束后那条连接会一直挂到客户端 20s idle 超时才重连）。这里补一条轻量 stream 事件，
    让阻塞的 xread 立刻醒来；它下一轮即读到 terminal 状态并发 `[DONE]`，秒出「下载并运行」按钮。
    必须在 set_status(terminal) 之后调用（Redis 单线程保证 HSET 先于 XADD 可见）。"""
    try:
        store.append_event(session_id, {"status": ai_session.STATUS_DONE})
    except Exception:
        logger.warning("[DEMO] wake-sse append failed sid=%s", session_id)


def _replay_worker(session_id: str, base: str, lang=None):
    store = ai_session.SessionStore()
    jsonl = _resolve_jsonl(base, lang)
    fresh = _resolve_app_url(base)
    final = {}
    try:
        with open(jsonl, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                ev = json.loads(line)
                # 录制末尾的哨兵行，重建终态 meta（final_text/client_actions 等）
                if isinstance(ev, dict) and "_demo_final" in ev:
                    final = ev.get("_demo_final") or {}
                    continue
                store.append_event(session_id, _rewrite_event_url(ev, fresh))
                time.sleep(_REPLAY_SLEEP)
    except FileNotFoundError:
        logger.error("[DEMO] replay file missing: %s", jsonl)
        store.append_event(session_id, {"status": "error", "message": "demo replay 暂不可用"})
        store.set_status(session_id, ai_session.STATUS_FAILED, error="demo replay not available")
        _wake_sse(store, session_id)
        return
    except Exception as e:
        logger.exception("[DEMO] replay failed sid=%s: %s", session_id, e)
        store.set_status(session_id, ai_session.STATUS_FAILED, error=str(e))
        _wake_sse(store, session_id)
        return

    actions = _rewrite_actions_url(final.get("client_actions") or [], fresh)
    store.set_status(
        session_id,
        ai_session.STATUS_DONE,
        final_text=final.get("final_text"),
        final_thinking=final.get("final_thinking"),
        client_actions=actions,
    )
    _wake_sse(store, session_id)
    logger.info("[DEMO] replay done sid=%s base=%s events_final=%s", session_id, base, bool(final))
