import SwiftUI
import SwiftData

@main
struct GoodsScannerApp: App {
    static let container: ModelContainer = {
        do { return try ModelContainer(for: Customer.self, InboundOrder.self, CargoItem.self) }
        catch { fatalError("Cannot open the database: \(error)") }
    }()
    /// Set by the onboarding's "I understand"; until then the tutorial + disclaimer cover the app.
    @AppStorage("disclaimerAccepted") private var disclaimerAccepted = false
    #if DEBUG
    @State private var tab = UserDefaults.standard.integer(forKey: "tab")  // `-tab <0-3>` launch arg, for screenshots
    #else
    @State private var tab = 0
    #endif

    init() {
        #if DEBUG
        if CommandLine.arguments.contains("-seedDemo") {
            Self.seedDemo(Self.container.mainContext)
            UserDefaults.standard.set(true, forKey: "disclaimerAccepted")  // demo/screenshot runs skip onboarding
        }
        if CommandLine.arguments.contains("-showOnboarding") { UserDefaults.standard.set(false, forKey: "disclaimerAccepted") }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            // `-scanStage c6-measuring` (any ScanStageScreen.cameraStages name): that scan stage full screen, for screenshots.
            if let stage = ScanStageScreen.cameraStages.first(where: { $0.name == UserDefaults.standard.string(forKey: "scanStage") }) {
                stage.screen
            } else { tabs }
            #else
            tabs
            #endif
        }
        .modelContainer(Self.container)
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            // Selected tab in accent (brand was too close to the black unselected icons); content keeps brand.
            OrdersView().tint(.brand).tabItem { Label("Inbound", systemImage: "shippingbox") }.tag(0)
            CustomersView().tint(.brand).tabItem { Label("Customers", systemImage: "person.2") }.tag(1)
            ReportsView().tint(.brand).tabItem { Label("Reports", systemImage: "chart.bar.doc.horizontal") }.tag(2)
            SettingsView().tint(.brand).tabItem { Label("Settings", systemImage: "gearshape") }.tag(3)
        }
        .tint(.accentText)
        .fullScreenCover(isPresented: .constant(!disclaimerAccepted)) { OnboardingView() }
    }

    #if DEBUG
    /// Demo data in the app's language (names only; numbers are identical in every locale). Re-seeds on every
    /// `-seedDemo` launch so the "Today" cards always count the two orders dated today.
    @MainActor static func seedDemo(_ ctx: ModelContext) {
        try? ctx.fetch(FetchDescriptor<InboundOrder>()).forEach(ctx.delete)
        try? ctx.save()
        try? ctx.fetch(FetchDescriptor<Customer>()).forEach(ctx.delete)
        // (customer A, contact, address, customer B, contact, address, operator, 7 item names)
        let t: [String: [String]] = [
            "en": ["Northwind Trading Co.", "James Carter", "Seattle, WA", "Harbor Home Furnishings", "Emily Chen", "Portland, OR", "Mike",
                   "Monitor", "Keyboard", "Laser printer", "Dining chair", "Coffee table", "Server chassis", "Mattress"],
            "zh-Hans": ["华东电子有限公司", "张伟", "上海市浦东新区", "南方家居", "李娜", "广州市白云区", "王师傅",
                        "显示器", "键盘", "激光打印机", "餐椅", "茶几", "服务器机箱", "床垫"],
            "zh-Hant": ["華東電子有限公司", "張偉", "台北市內湖區", "南方家居", "李娜", "高雄市前鎮區", "王師傅",
                        "顯示器", "鍵盤", "雷射印表機", "餐椅", "茶几", "伺服器機殼", "床墊"],
            "ja": ["北和商事株式会社", "佐藤 健", "東京都江東区", "みなと家具株式会社", "鈴木 花子", "大阪市住之江区", "田中",
                   "モニター", "キーボード", "レーザープリンター", "ダイニングチェア", "ローテーブル", "サーバーケース", "マットレス"],
            "ko": ["한빛무역 주식회사", "김민준", "서울시 송파구", "바다가구", "이서연", "부산시 해운대구", "박 반장",
                   "모니터", "키보드", "레이저 프린터", "식탁 의자", "커피 테이블", "서버 케이스", "매트리스"],
            "es": ["Comercial Vientonorte S.L.", "Javier García", "Madrid", "Muebles del Puerto", "Lucía Martín", "Valencia", "Carlos",
                   "Monitor", "Teclado", "Impresora láser", "Silla de comedor", "Mesa de centro", "Caja de servidor", "Colchón"],
            "fr": ["Négoce Ventnord SARL", "Julien Martin", "Lyon", "Maison du Port", "Camille Bernard", "Marseille", "Thomas",
                   "Écran", "Clavier", "Imprimante laser", "Chaise", "Table basse", "Boîtier serveur", "Matelas"],
            "de": ["Nordwind Handels GmbH", "Lukas Müller", "Hamburg", "Hafen Wohnwelt KG", "Anna Schmidt", "Bremen", "Jonas",
                   "Monitor", "Tastatur", "Laserdrucker", "Esszimmerstuhl", "Couchtisch", "Servergehäuse", "Matratze"],
            "pt-BR": ["Ventonorte Comércio Ltda.", "Rafael Souza", "São Paulo, SP", "Porto Móveis", "Ana Oliveira", "Santos, SP", "Bruno",
                      "Monitor", "Teclado", "Impressora a laser", "Cadeira de jantar", "Mesa de centro", "Gabinete de servidor", "Colchão"],
            "ru": ["ООО «Северный ветер»", "Иван Петров", "Москва", "Гавань Мебель", "Анна Смирнова", "Санкт-Петербург", "Сергей",
                   "Монитор", "Клавиатура", "Лазерный принтер", "Обеденный стул", "Журнальный столик", "Серверный корпус", "Матрас"],
            "vi": ["Công ty TNHH Gió Bắc", "Nguyễn Văn An", "TP. Hồ Chí Minh", "Nội thất Bến Cảng", "Trần Thị Mai", "Hải Phòng", "Anh Hùng",
                   "Màn hình", "Bàn phím", "Máy in laser", "Ghế ăn", "Bàn trà", "Vỏ máy chủ", "Nệm"],
        ]
        let s = t[Bundle.main.preferredLocalizations.first ?? "en"] ?? t["en"]!
        let a = Customer(code: "C001", name: s[0], contact: s[1], phone: "13800000001", address: s[2])
        let b = Customer(code: "C002", name: s[3], contact: s[4], phone: "13900000002", address: s[5])
        ctx.insert(a); ctx.insert(b)
        let today = Calendar.current.startOfDay(for: .now)
        // (customer, minutes after today's midnight (negative = earlier days), [(item, L, W, H cm, pieces, total kg, method)])
        let specs: [(Customer, Int, [(Int, Double, Double, Double, Int, Double?, String)])] = [
            (a, 9 * 60 + 15, [(7, 60, 45, 20, 10, 85, "lidar"), (8, 48, 18, 6, 50, 60, "manual"), (9, 52, 45, 38, 6, 87, "lidar")]),
            (b, 8 * 60 + 40, [(10, 55, 50, 90, 4, 24, "camera"), (11, 120, 60, 45, 1, 32, "lidar")]),
            (a, -10 * 60, [(12, 80, 60, 25, 2, 44, "lidar")]),
            (b, -62 * 60, [(13, 200, 150, 25, 3, 54, "lidar")]),
        ]
        for (c, minutes, items) in specs {
            let date = today.addingTimeInterval(Double(minutes) * 60)
            let no = (try? InboundOrder.nextOrderNo(for: date, in: ctx)) ?? UUID().uuidString
            let o = InboundOrder(orderNo: no, customer: c, receivedAt: date, operatorName: s[6])
            ctx.insert(o)
            for i in items {
                let item = CargoItem(name: s[i.0], lengthCm: i.1, widthCm: i.2, heightCm: i.3, quantity: i.4, weightKg: i.5,
                                     method: i.6, confidence: i.6 == "manual" ? nil : 0.97)
                ctx.insert(item)
                item.order = o
            }
            try? ctx.save()
        }
    }
    #endif
}
