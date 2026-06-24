import 'package:flutter/widgets.dart';

// 框架 shell（设置/Agent 调度/私有节点/市场/首页）里历史上用本地 switch 或
// zh?:en 三元做的文案，集中补齐到 11 种语言。键是英文原文。
// JSON-APP 内部 i18n 不在此处；这里只覆盖框架自身的原生 Dart UI。

const Map<String, Map<String, String>> adminExtraI18n = {
  'Agent routing': {'fr': 'Routage des agents', 'pt': 'Encaminhamento de agentes', 'ca': 'Encaminament d\'agents', 'hi': 'Agent रूटिंग', 'ko': '에이전트 라우팅', 'ja': 'エージェントルーティング', 'it': 'Instradamento agente'},
  'Platform': {'fr': 'Plateforme', 'pt': 'Plataforma', 'ca': 'Plataforma', 'hi': 'प्लेटफ़ॉर्म', 'ko': '플랫폼', 'ja': 'プラットフォーム', 'it': 'Piattaforma'},
  'Private': {'fr': 'Privé', 'pt': 'Privado', 'ca': 'Privat', 'hi': 'निजी', 'ko': '프라이빗', 'ja': 'プライベート', 'it': 'Privato'},
  'Platform uses only public Agent Nodes. Private uses only your nodes. Provider choices follow the selected mode.': {'fr': 'Le mode Plateforme n\'utilise que les Agent Nodes publics. Le mode Privé n\'utilise que vos nodes. Le choix du Provider dépend du mode sélectionné.', 'pt': 'A plataforma usa apenas Nós de Agente públicos. O modo privado usa apenas os seus nós. As opções de fornecedor seguem o modo selecionado.', 'ca': 'La plataforma només fa servir Agent Nodes públics. El mode privat només fa servir els teus nodes. Les opcions de proveïdor segueixen el mode seleccionat.', 'hi': 'प्लेटफ़ॉर्म केवल सार्वजनिक Agent Node उपयोग करता है। निजी केवल आपके नोड उपयोग करता है। Provider के विकल्प चयनित मोड के अनुसार होते हैं।', 'ko': '플랫폼은 공용 에이전트 노드만 사용하고, 프라이빗은 내 노드만 사용합니다. 제공자 선택은 선택한 모드를 따릅니다.', 'ja': 'プラットフォームは公開エージェントノードのみを使用します。プライベートはご自身のノードのみを使用します。プロバイダーの選択肢は選択したモードに従います。', 'it': 'La piattaforma usa solo Agent Node pubblici. La modalità privata usa solo i tuoi nodi. Le scelte del provider seguono la modalità selezionata.'},
  'Private Agent Node': {'fr': 'Agent Node privé', 'pt': 'Nó de Agente privado', 'ca': 'Agent Node privat', 'hi': 'निजी Agent Node', 'ko': '프라이빗 에이전트 노드', 'ja': 'プライベートエージェントノード', 'it': 'Agent Node privato'},
  'View your private nodes, create join commands, pause routing, or adjust limits': {'fr': 'Consultez vos nodes privés, créez des commandes d\'ajout, suspendez le routage ou ajustez les limites', 'pt': 'Veja os seus nós privados, crie comandos de adesão, pause o encaminhamento ou ajuste os limites', 'ca': 'Consulta els teus nodes privats, crea ordres d\'incorporació, pausa l\'encaminament o ajusta els límits', 'hi': 'अपने निजी नोड देखें, join कमांड बनाएँ, रूटिंग रोकें, या सीमाएँ समायोजित करें', 'ko': '내 프라이빗 노드 보기, 참여 명령 생성, 라우팅 일시중지 또는 한도 조정', 'ja': 'プライベートノードの確認、参加コマンドの作成、ルーティングの一時停止、上限の調整ができます', 'it': 'Visualizza i tuoi nodi privati, crea comandi di adesione, metti in pausa l\'instradamento o modifica i limiti'},
  'My Service Groups (FaaS + DB)': {'fr': 'Mes groupes de services (FaaS + BDD)', 'pt': 'Os meus Grupos de Serviços (FaaS + BD)', 'ca': 'Els meus grups de serveis (FaaS + BD)', 'hi': 'मेरे सेवा समूह (FaaS + DB)', 'ko': '내 서비스 그룹 (FaaS + DB)', 'ja': 'マイサービスグループ（FaaS + DB）', 'it': 'I miei gruppi di servizi (FaaS + DB)'},
  'Manage your FaaS services & database, access policy, maintainers and granted users': {'fr': 'Gérez vos services FaaS et bases de données, la politique d\'accès, les mainteneurs et les utilisateurs autorisés', 'pt': 'Faça a gestão dos seus serviços FaaS e base de dados, política de acesso, mantenedores e utilizadores autorizados', 'ca': 'Gestiona els teus serveis FaaS i la base de dades, la política d\'accés, els mantenidors i els usuaris autoritzats', 'hi': 'अपनी FaaS सेवाएँ और डेटाबेस, एक्सेस नीति, मेंटेनर और अनुमत उपयोगकर्ता प्रबंधित करें', 'ko': 'FaaS 서비스 및 데이터베이스, 접근 정책, 관리자, 권한 부여 사용자를 관리합니다', 'ja': 'FaaS サービスとデータベース、アクセスポリシー、メンテナー、許可ユーザーを管理します', 'it': 'Gestisci i tuoi servizi FaaS e il database, i criteri di accesso, i manutentori e gli utenti autorizzati'},
  'Please sign in first': {'fr': 'Veuillez d\'abord vous connecter', 'pt': 'Inicie sessão primeiro', 'ca': 'Inicia la sessió primer', 'hi': 'कृपया पहले साइन इन करें', 'ko': '먼저 로그인해 주세요', 'ja': '先にサインインしてください', 'it': 'Accedi prima'},
  'Sign in before creating a private Agent Node join command': {'fr': 'Connectez-vous avant de créer une commande d\'ajout d\'Agent Node privé', 'pt': 'Inicie sessão antes de criar um comando de adesão de Nó de Agente privado', 'ca': 'Inicia la sessió abans de crear una ordre d\'incorporació d\'un Agent Node privat', 'hi': 'निजी Agent Node join कमांड बनाने से पहले साइन इन करें', 'ko': '프라이빗 에이전트 노드 참여 명령을 생성하기 전에 로그인하세요', 'ja': 'プライベートエージェントノードの参加コマンドを作成する前にサインインしてください', 'it': 'Accedi prima di creare un comando di adesione per un Agent Node privato'},
  'My private node': {'fr': 'Mon node privé', 'pt': 'O meu nó privado', 'ca': 'El meu node privat', 'hi': 'मेरा निजी नोड', 'ko': '내 프라이빗 노드', 'ja': 'マイプライベートノード', 'it': 'Il mio nodo privato'},
  'Node name': {'fr': 'Nom du node', 'pt': 'Nome do nó', 'ca': 'Nom del node', 'hi': 'नोड का नाम', 'ko': '노드 이름', 'ja': 'ノード名', 'it': 'Nome del nodo'},
  'Shown in lists and dashboards': {'fr': 'Affiché dans les listes et les tableaux de bord', 'pt': 'Apresentado em listas e painéis', 'ca': 'Es mostra a les llistes i als taulers', 'hi': 'सूचियों और डैशबोर्ड में दिखाया जाता है', 'ko': '목록과 대시보드에 표시됩니다', 'ja': '一覧やダッシュボードに表示されます', 'it': 'Mostrato negli elenchi e nelle dashboard'},
  'Cancel': {'fr': 'Annuler', 'pt': 'Cancelar', 'ca': 'Cancel·la', 'hi': 'रद्द करें', 'ko': '취소', 'ja': 'キャンセル', 'it': 'Annulla'},
  'Create': {'fr': 'Créer', 'pt': 'Criar', 'ca': 'Crea', 'hi': 'बनाएँ', 'ko': '생성', 'ja': '作成', 'it': 'Crea'},
  'Private Agent Node join command': {'fr': 'Commande d\'ajout d\'Agent Node privé', 'pt': 'Comando de adesão de Nó de Agente privado', 'ca': 'Ordre d\'incorporació de l\'Agent Node privat', 'hi': 'निजी Agent Node join कमांड', 'ko': '프라이빗 에이전트 노드 참여 명령', 'ja': 'プライベートエージェントノードの参加コマンド', 'it': 'Comando di adesione Agent Node privato'},
  'This is a one-time short-lived token. Run it on your agent host; provider keys stay local on that host.': {'fr': 'Ce jeton est à usage unique et de courte durée. Exécutez-le sur votre hôte d\'agent ; les clés du Provider restent locales sur cet hôte.', 'pt': 'Este é um token de utilização única e de curta duração. Execute-o no anfitrião do seu agente; as chaves do fornecedor permanecem locais nesse anfitrião.', 'ca': 'Aquest és un token d\'un sol ús i de curta durada. Executa\'l al teu host d\'agent; les claus del proveïdor es queden en local en aquest host.', 'hi': 'यह एक बार उपयोग होने वाला अल्पकालिक टोकन है। इसे अपने agent होस्ट पर चलाएँ; provider कुंजियाँ उसी होस्ट पर स्थानीय रहती हैं।', 'ko': '이것은 일회성 단기 토큰입니다. 에이전트 호스트에서 실행하세요. 제공자 키는 해당 호스트에만 로컬로 보관됩니다.', 'ja': 'これは一度限りの短期トークンです。エージェントホスト上で実行してください。プロバイダーキーはそのホスト内にローカルで保持されます。', 'it': 'Questo è un token monouso a breve durata. Eseguilo sul tuo host agente; le chiavi del provider restano locali su quell\'host.'},
  'Copy command': {'fr': 'Copier la commande', 'pt': 'Copiar comando', 'ca': 'Copia l\'ordre', 'hi': 'कमांड कॉपी करें', 'ko': '명령 복사', 'ja': 'コマンドをコピー', 'it': 'Copia comando'},
  'Private Agent Node join command copied': {'fr': 'Commande d\'ajout d\'Agent Node privé copiée', 'pt': 'Comando de adesão de Nó de Agente privado copiado', 'ca': 'S\'ha copiat l\'ordre d\'incorporació de l\'Agent Node privat', 'hi': 'निजी Agent Node join कमांड कॉपी हो गई', 'ko': '프라이빗 에이전트 노드 참여 명령이 복사되었습니다', 'ja': 'プライベートエージェントノードの参加コマンドをコピーしました', 'it': 'Comando di adesione Agent Node privato copiato'},
  'Private Agent Nodes': {'fr': 'Agent Nodes privés', 'pt': 'Nós de Agente privados', 'ca': 'Agent Nodes privats', 'hi': 'निजी Agent Node', 'ko': '프라이빗 에이전트 노드', 'ja': 'プライベートエージェントノード', 'it': 'Agent Node privati'},
  'Refresh': {'fr': 'Actualiser', 'pt': 'Atualizar', 'ca': 'Actualitza', 'hi': 'रिफ़्रेश करें', 'ko': '새로고침', 'ja': '更新', 'it': 'Aggiorna'},
  'Join node': {'fr': 'Ajouter un node', 'pt': 'Aderir ao nó', 'ca': 'Incorpora un node', 'hi': 'नोड जोड़ें', 'ko': '노드 참여', 'ja': 'ノードを参加', 'it': 'Aggiungi nodo'},
  'Sign in to register and monitor private Agent Nodes that only belong to you.': {'fr': 'Connectez-vous pour enregistrer et surveiller des Agent Nodes privés qui n\'appartiennent qu\'à vous.', 'pt': 'Inicie sessão para registar e monitorizar Nós de Agente privados que pertencem apenas a si.', 'ca': 'Inicia la sessió per registrar i supervisar Agent Nodes privats que només et pertanyen a tu.', 'hi': 'केवल अपने निजी Agent Node को पंजीकृत और मॉनिटर करने के लिए साइन इन करें।', 'ko': '나만의 프라이빗 에이전트 노드를 등록하고 모니터링하려면 로그인하세요.', 'ja': 'サインインすると、ご自身専用のプライベートエージェントノードを登録・監視できます。', 'it': 'Accedi per registrare e monitorare gli Agent Node privati che appartengono solo a te.'},
  'Sign in': {'fr': 'Se connecter', 'pt': 'Iniciar sessão', 'ca': 'Inicia la sessió', 'hi': 'साइन इन करें', 'ko': '로그인', 'ja': 'サインイン', 'it': 'Accedi'},
  'My private nodes': {'fr': 'Mes nodes privés', 'pt': 'Os meus nós privados', 'ca': 'Els meus nodes privats', 'hi': 'मेरे निजी नोड', 'ko': '내 프라이빗 노드', 'ja': 'マイプライベートノード', 'it': 'I miei nodi privati'},
  'Total': {'fr': 'Total', 'pt': 'Total', 'ca': 'Total', 'hi': 'कुल', 'ko': '전체', 'ja': '合計', 'it': 'Totale'},
  'Online': {'fr': 'En ligne', 'pt': 'Online', 'ca': 'En línia', 'hi': 'ऑनलाइन', 'ko': '온라인', 'ja': 'オンライン', 'it': 'Online'},
  'Running': {'fr': 'En cours', 'pt': 'Em execução', 'ca': 'En execució', 'hi': 'चल रहे', 'ko': '실행 중', 'ja': '実行中', 'it': 'In esecuzione'},
  'Queue': {'fr': 'File d\'attente', 'pt': 'Fila', 'ca': 'Cua', 'hi': 'कतार', 'ko': '대기열', 'ja': 'キュー', 'it': 'Coda'},
  'No private Agent Nodes yet': {'fr': 'Aucun Agent Node privé pour le moment', 'pt': 'Ainda não existem Nós de Agente privados', 'ca': 'Encara no hi ha cap Agent Node privat', 'hi': 'अभी कोई निजी Agent Node नहीं', 'ko': '아직 프라이빗 에이전트 노드가 없습니다', 'ja': 'プライベートエージェントノードはまだありません', 'it': 'Ancora nessun Agent Node privato'},
  'Tap the button below to create a join command. Run it on your host and it will appear here.': {'fr': 'Appuyez sur le bouton ci-dessous pour créer une commande d\'ajout. Exécutez-la sur votre hôte et elle apparaîtra ici.', 'pt': 'Toque no botão abaixo para criar um comando de adesão. Execute-o no seu anfitrião e ele aparecerá aqui.', 'ca': 'Toca el botó de sota per crear una ordre d\'incorporació. Executa-la al teu host i apareixerà aquí.', 'hi': 'join कमांड बनाने के लिए नीचे बटन दबाएँ। इसे अपने होस्ट पर चलाएँ और यह यहाँ दिखाई देगा।', 'ko': '아래 버튼을 눌러 참여 명령을 생성하세요. 호스트에서 실행하면 여기에 표시됩니다.', 'ja': '下のボタンをタップして参加コマンドを作成してください。ホスト上で実行するとここに表示されます。', 'it': 'Tocca il pulsante qui sotto per creare un comando di adesione. Eseguilo sul tuo host e apparirà qui.'},
  'running': {'fr': 'en cours', 'pt': 'em execução', 'ca': 'en execució', 'hi': 'चल रहा है', 'ko': '실행 중', 'ja': '実行中', 'it': 'in esecuzione'},
  'queued': {'fr': 'en file d\'attente', 'pt': 'em fila', 'ca': 'a la cua', 'hi': 'कतार में', 'ko': '대기 중', 'ja': 'キュー待ち', 'it': 'in coda'},
  'Status is synced from node heartbeats. Pause, resume, limits, and removal must be changed with myapp-ctl on this Agent Node host.': {'fr': 'L\'état est synchronisé à partir des signaux de présence des nodes. La suspension, la reprise, les limites et la suppression doivent être modifiées avec myapp-ctl sur cet hôte d\'Agent Node.', 'pt': 'O estado é sincronizado a partir dos sinais de atividade do nó. A pausa, retoma, limites e remoção têm de ser alterados com o myapp-ctl neste anfitrião de Nó de Agente.', 'ca': 'L\'estat se sincronitza a partir dels batecs del node. La pausa, la represa, els límits i l\'eliminació s\'han de canviar amb myapp-ctl en aquest host de l\'Agent Node.', 'hi': 'स्थिति नोड हार्टबीट से सिंक होती है। रोकना, फिर से शुरू करना, सीमाएँ और हटाना इस Agent Node होस्ट पर myapp-ctl से बदलना होगा।', 'ko': '상태는 노드 하트비트로부터 동기화됩니다. 일시중지, 재개, 한도 및 제거는 이 에이전트 노드 호스트에서 myapp-ctl로 변경해야 합니다.', 'ja': 'ステータスはノードのハートビートから同期されます。一時停止、再開、上限、削除は、このエージェントノードホスト上で myapp-ctl を使って変更してください。', 'it': 'Lo stato è sincronizzato dagli heartbeat del nodo. Pausa, ripresa, limiti e rimozione devono essere modificati con myapp-ctl su questo host Agent Node.'},
};

const Map<String, Map<String, String>> marketExtraI18n = {
  'Loading versions': {'de': 'Versionen laden', 'es': 'Cargando versiones', 'fr': 'Chargement des versions', 'pt': 'A carregar versões', 'ca': 'S\'estan carregant les versions', 'hi': 'संस्करण लोड हो रहे हैं', 'ko': '버전 불러오는 중', 'ja': 'バージョンを読み込み中', 'it': 'Caricamento versioni'},
  'Details': {'de': 'Details', 'es': 'Detalles', 'fr': 'Détails', 'pt': 'Detalhes', 'ca': 'Detalls', 'hi': 'विवरण', 'ko': '상세 정보', 'ja': '詳細', 'it': 'Dettagli'},
  'Favorite': {'de': 'Favorit', 'es': 'Favorito', 'fr': 'Favori', 'pt': 'Adicionar aos favoritos', 'ca': 'Preferit', 'hi': 'पसंदीदा', 'ko': '즐겨찾기', 'ja': 'お気に入り', 'it': 'Preferito'},
  'About': {'de': 'Übersicht', 'es': 'Acerca de', 'fr': 'À propos', 'pt': 'Acerca de', 'ca': 'Quant a', 'hi': 'परिचय', 'ko': '소개', 'ja': '概要', 'it': 'Informazioni'},
  'Tech stack': {'de': 'Tech-Stack', 'es': 'Tecnologías', 'fr': 'Pile technique', 'pt': 'Pilha tecnológica', 'ca': 'Pila tecnològica', 'hi': 'टेक स्टैक', 'ko': '기술 스택', 'ja': '技術スタック', 'it': 'Stack tecnologico'},
  'Features': {'de': 'Funktionen', 'es': 'Funciones', 'fr': 'Fonctionnalités', 'pt': 'Funcionalidades', 'ca': 'Funcions', 'hi': 'विशेषताएँ', 'ko': '기능', 'ja': '機能', 'it': 'Funzionalità'},
  'Run': {'de': 'Ausführen', 'es': 'Ejecutar', 'fr': 'Lancer', 'pt': 'Executar', 'ca': 'Executa', 'hi': 'चलाएँ', 'ko': '실행', 'ja': '実行', 'it': 'Esegui'},
  'Unknown': {'de': 'Unbekannt', 'es': 'Desconocido', 'fr': 'Inconnu', 'pt': 'Desconhecido', 'ca': 'Desconegut', 'hi': 'अज्ञात', 'ko': '알 수 없음', 'ja': '不明', 'it': 'Sconosciuto'},
  'Author': {'de': 'Autor', 'es': 'Autor', 'fr': 'Auteur', 'pt': 'Autor', 'ca': 'Autor', 'hi': 'लेखक', 'ko': '작성자', 'ja': '作者', 'it': 'Autore'},
  'Downloads': {'de': 'Downloads', 'es': 'Descargas', 'fr': 'Téléchargements', 'pt': 'Transferências', 'ca': 'Baixades', 'hi': 'डाउनलोड', 'ko': '다운로드', 'ja': 'ダウンロード数', 'it': 'Download'},
  'Likes': {'de': 'Likes', 'es': 'Me gusta', 'fr': 'J\'aime', 'pt': 'Gostos', 'ca': 'M\'agrada', 'hi': 'पसंद', 'ko': '좋아요', 'ja': 'いいね', 'it': 'Mi piace'},
  'Apps': {'de': 'Apps', 'es': 'Apps', 'fr': 'Applications', 'pt': 'Apps', 'ca': 'Apps', 'hi': 'ऐप्स', 'ko': '앱', 'ja': 'アプリ', 'it': 'App'},
  'Space': {'de': 'Bereich', 'es': 'Espacio', 'fr': 'Espace', 'pt': 'Espaço', 'ca': 'Espai', 'hi': 'स्पेस', 'ko': '스페이스', 'ja': 'スペース', 'it': 'Spazio'},
  'Official': {'de': 'Offiziell', 'es': 'Oficial', 'fr': 'Officiel', 'pt': 'Oficial', 'ca': 'Oficial', 'hi': 'आधिकारिक', 'ko': '공식', 'ja': '公式', 'it': 'Ufficiale'},
  'Favorites': {'de': 'Favoriten', 'es': 'Favoritos', 'fr': 'Favoris', 'pt': 'Favoritos', 'ca': 'Preferits', 'hi': 'पसंदीदा', 'ko': '즐겨찾기', 'ja': 'お気に入り', 'it': 'Preferiti'},
};

/// 历史 {zh,en,de,es} switch 的 11 语言替代：新语言查 adminExtraI18n，回退 en。
String adminTr(
  BuildContext context, {
  required String zh,
  required String en,
  required String de,
  required String es,
}) {
  switch (Localizations.localeOf(context).languageCode) {
    case 'zh':
      return zh;
    case 'en':
      return en;
    case 'de':
      return de;
    case 'es':
      return es;
    default:
      return adminExtraI18n[en]?[Localizations.localeOf(context).languageCode] ?? en;
  }
}

/// 历史 `_isZh ? zh : en` 三元的 11 语言替代：zh/en 内联，其余查 marketExtraI18n，回退 en。
String localePick(BuildContext context, String zh, String en) {
  final code = Localizations.localeOf(context).languageCode;
  if (code == 'zh') return zh;
  if (code == 'en') return en;
  return marketExtraI18n[en]?[code] ?? en;
}
