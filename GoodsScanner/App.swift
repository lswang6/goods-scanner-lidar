import SwiftUI
import SwiftData

@main
struct GoodsScannerApp: App {
    static let container: ModelContainer = {
        do { return try ModelContainer(for: Customer.self, InboundOrder.self, CargoItem.self) }
        catch { fatalError("无法打开数据库: \(error)") }
    }()
    /// Set by the onboarding's "I understand"; until then the tutorial + disclaimer cover the app.
    @AppStorage("disclaimerAccepted") private var disclaimerAccepted = false

    init() {
        #if DEBUG
        if CommandLine.arguments.contains("-seedDemo") {
            Self.seedDemo(Self.container.mainContext)
            UserDefaults.standard.set(true, forKey: "disclaimerAccepted")  // demo/screenshot runs skip onboarding
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                // Selected tab in accent (brand was too close to the black unselected icons); content keeps brand.
                OrdersView().tint(.brand).tabItem { Label("入库", systemImage: "shippingbox") }
                CustomersView().tint(.brand).tabItem { Label("客户", systemImage: "person.2") }
                ReportsView().tint(.brand).tabItem { Label("报表", systemImage: "chart.bar.doc.horizontal") }
                SettingsView().tint(.brand).tabItem { Label("设置", systemImage: "gearshape") }
            }
            .tint(.accentText)
            .fullScreenCover(isPresented: .constant(!disclaimerAccepted)) { OnboardingView() }
        }
        .modelContainer(Self.container)
    }

    #if DEBUG
    @MainActor static func seedDemo(_ ctx: ModelContext) {
        guard (try? ctx.fetchCount(FetchDescriptor<Customer>())) == 0 else { return }
        let a = Customer(code: "C001", name: "华东电子有限公司", contact: "张伟", phone: "13800000001", address: "上海市浦东新区")
        let b = Customer(code: "C002", name: "南方家居", contact: "李娜", phone: "13900000002", address: "广州市白云区")
        ctx.insert(a); ctx.insert(b)
        let now = Date.now
        let specs: [(Customer, Int, [(String, Double, Double, Double, Int, Double?, String)])] = [
            (a, 0, [("显示器", 60, 45, 20, 10, 8.5, "lidar"), ("键盘", 48, 18, 6, 50, 1.2, "manual")]),
            (a, -1, [("服务器机箱", 80, 60, 25, 2, 22, "lidar")]),
            (b, 0, [("餐椅", 55, 50, 90, 4, 6, "manual"), ("茶几", 120, 60, 45, 1, nil, "lidar")]),
            (b, -3, [("床垫", 200, 150, 25, 3, 18, "manual")]),
        ]
        for (c, dayOffset, items) in specs {
            let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: now)!
            let no = (try? InboundOrder.nextOrderNo(for: date, in: ctx)) ?? UUID().uuidString
            let o = InboundOrder(orderNo: no, customer: c, receivedAt: date, operatorName: "王师傅")
            ctx.insert(o)
            for i in items {
                let item = CargoItem(name: i.0, lengthCm: i.1, widthCm: i.2, heightCm: i.3, quantity: i.4, weightKg: i.5,
                                     method: i.6, confidence: i.6 == "lidar" ? 0.97 : nil)
                ctx.insert(item)
                item.order = o
            }
            try? ctx.save()
        }
    }
    #endif
}
