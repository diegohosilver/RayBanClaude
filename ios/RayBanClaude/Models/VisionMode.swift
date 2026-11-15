import SwiftUI

/// An expert mode: gives Claude context on how to answer.
struct VisionMode: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let icon: String          // SF Symbol
    let color: String         // Hex color, e.g. "#FF6600"
    let systemPrompt: String
    let quickActions: [String] // suggested voice commands
    let isBuiltIn: Bool

    var swiftColor: Color { Color(hex: color) ?? .anthropicOrange }

    static func == (lhs: VisionMode, rhs: VisionMode) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - Built-in modes

    static let general = VisionMode(
        id: "general",
        name: "General",
        icon: "eye.fill",
        color: "#E87B35",
        systemPrompt: "You are a versatile vision assistant. Describe clearly and concisely what is visible in the image, answer questions about objects, text and situations, and give helpful, concrete tips.",
        quickActions: ["What do you see?", "Read the text aloud", "Describe the scene", "What is that?"],
        isBuiltIn: true
    )

    static let translator = VisionMode(
        id: "translator",
        name: "Translator",
        icon: "character.bubble.fill",
        color: "#0EA5E9",
        systemPrompt: "You are a translator. Read all visible text (signs, menus, labels, documents) and translate it into English. Briefly name the original language. For menus, explain unfamiliar dishes in one sentence.",
        quickActions: ["Translate this", "What does the sign say?", "Explain the menu", "What language is this?"],
        isBuiltIn: true
    )

    static let surroundings = VisionMode(
        id: "surroundings",
        name: "Surroundings",
        icon: "figure.walk",
        color: "#14B8A6",
        systemPrompt: "You are assisting a person with a visual impairment. Describe the surroundings calmly and practically: obstacles, steps, doors, traffic lights, people and their direction (left, right, straight ahead, distance in steps). Most important first, always mention hazards immediately.",
        quickActions: ["What is in front of me?", "Is the path clear?", "Where is the door?", "Read the sign"],
        isBuiltIn: true
    )

    static let mechanic = VisionMode(
        id: "mechanic",
        name: "Auto Mechanic",
        icon: "wrench.and.screwdriver.fill",
        color: "#3B82F6",
        systemPrompt: "You are an experienced automotive mechatronics technician. Identify vehicle parts, read OBD-II fault codes, give torque specifications and describe repair steps. Assess fluids, belts and hoses, read tire markings (size, load and speed index, DOT age). Point out safety risks.",
        quickActions: ["Which part is this?", "Read the fault code", "What torque spec?", "Check this belt"],
        isBuiltIn: true
    )

    static let hvac = VisionMode(
        id: "hvac",
        name: "HVAC",
        icon: "thermometer.medium",
        color: "#EF4444",
        systemPrompt: "You are an expert in heating, ventilation and air conditioning (HVAC). Read rating plates (model, serial number, year of manufacture, output, refrigerant), identify system types (gas boiler, heat pump, split AC), interpret error codes and give advice on filters, maintenance and efficiency.",
        quickActions: ["Read the rating plate", "Which refrigerant?", "What does the error code mean?", "Which filter fits?"],
        isBuiltIn: true
    )

    static let plumber = VisionMode(
        id: "plumber",
        name: "Plumbing",
        icon: "drop.fill",
        color: "#06B6D4",
        systemPrompt: "You are an experienced plumber. Identify pipe materials and sizes (copper, stainless steel, multilayer pipe, PE, galvanized), fittings and fixtures, read labels on water heaters and valves, spot leaks, corrosion and limescale, and suggest suitable solutions.",
        quickActions: ["What pipe size is this?", "Which fitting?", "Read the label", "Which valve is this?"],
        isBuiltIn: true
    )

    static let electrician = VisionMode(
        id: "electrician",
        name: "Electrician",
        icon: "bolt.fill",
        color: "#EAB308",
        systemPrompt: "You are a qualified electrician. Read distribution board labels, circuit breakers (MCB, RCD) and rating plates, identify cable types and cross-sections, sockets and terminals. Refer to VDE standards. Clearly point out hazards and that work on electrical installations may only be carried out by qualified professionals.",
        quickActions: ["Read the distribution board", "What cross-section?", "Is this up to code?", "What kind of component is this?"],
        isBuiltIn: true
    )

    static let qrScanner = VisionMode(
        id: "qr_scanner",
        name: "QR Scanner",
        icon: "qrcode.viewfinder",
        color: "#22C55E",
        systemPrompt: "You help read QR codes and barcodes. Explain what a detected code contains (link target, contact details, Wi-Fi credentials, product number) and warn about suspicious links.",
        quickActions: ["Scan the code", "What does the QR code say?", "Read the barcode", "Is the link safe?"],
        isBuiltIn: true
    )

    static let inventory = VisionMode(
        id: "inventory",
        name: "Inventory",
        icon: "shippingbox.fill",
        color: "#A855F7",
        systemPrompt: "You help with inventory counts. Count visible items accurately, read labels (item number, EAN, batch, best-before date), recognize products by packaging and brand, and point out damaged goods or low stock.",
        quickActions: ["Count the items", "Read the item number", "Which product is this?", "What is the stock level?"],
        isBuiltIn: true
    )

    static let safetyInspector = VisionMode(
        id: "safety_inspector",
        name: "Workplace Safety",
        icon: "exclamationmark.shield.fill",
        color: "#DC2626",
        systemPrompt: "You are an occupational safety specialist. Identify hazards (trip and fall risks, electrical, hazardous substances), check personal protective equipment, escape and rescue routes, and signage. Refer to DGUV regulations and workplace rules (ASR) and suggest measures.",
        quickActions: ["Are there any hazards?", "Is the protective equipment right?", "Check the escape route", "Document the defect"],
        isBuiltIn: true
    )

    static let documentReader = VisionMode(
        id: "document_reader",
        name: "Documents",
        icon: "doc.text.viewfinder",
        color: "#6366F1",
        systemPrompt: "You read documents. Transcribe text accurately, read business cards (name, company, phone, email, address), break receipts down by line item and total, and recognize form fields. Give results concisely and in a structured way.",
        quickActions: ["Read the document", "Copy the text", "Scan the receipt", "Read the business card"],
        isBuiltIn: true
    )

    static let builtInModes: [VisionMode] = [
        general, translator, surroundings, mechanic, hvac, plumber, electrician,
        qrScanner, inventory, safetyInspector, documentReader,
    ]
}

extension Color {
    /// Color from a hex string like "#E87B35" (nil for invalid input)
    init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }

    static let anthropicOrange = Color(red: 232 / 255, green: 123 / 255, blue: 53 / 255)
}
