import Foundation

/// Grammaire GBNF d'une décision d'agent : le modèle ne peut produire QUE du JSON conforme au protocole de GHOST CORE
/// (action parmi cinq valeurs, outil parmi ceux du catalogue réellement proposé, arguments textuels).
enum AgentGrammar {
    /// Noms d'outils proposés dans le prompt (lignes « - nom(arguments) : description »).
    static func toolNames(in system: String) -> [String] {
        system.split(separator: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- "), let open = t.firstIndex(of: "(") else { return nil }
            let name = String(t[t.index(t.startIndex, offsetBy: 2)..<open])
            return name.range(of: #"^[a-z_]+$"#, options: .regularExpression) != nil ? name : nil
        }
    }

    /// Actions autorisées à cette étape (ligne « Actions autorisées maintenant : a, b, c. » du prompt) ; toutes si la ligne est absente.
    static func actions(in system: String) -> [String] {
        let all = ["tool_call", "create_plan", "clarification_required", "final_response", "blocked"]
        guard let line = system.split(separator: "\n").first(where: { $0.contains("Actions autorisées maintenant :") }) else { return all }
        let listed = line.split(separator: ":", maxSplits: 1).last.map { $0.split(whereSeparator: { $0 == "," || $0 == "." || $0 == " " }).map(String.init) } ?? []
        let chosen = all.filter(listed.contains)
        return chosen.isEmpty ? all : chosen
    }

    static func gbnf(tools: [String], actions: [String] = ["tool_call", "create_plan", "clarification_required", "final_response", "blocked"]) -> String {
        let actionRule = actions.map { "\"\\\"\($0)\\\"\"" }.joined(separator: " | ")
        let toolRule = tools.isEmpty ? "string" : tools.map { "\"\\\"\($0)\\\"\"" }.joined(separator: " | ")
        return #"""
        root ::= "{" ws "\"action\"" ws ":" ws action (ws "," ws member)* ws "}"
        action ::= \#(actionRule)
        member ::= text | call | plan
        text ::= "\"text\"" ws ":" ws string
        call ::= "\"toolCall\"" ws ":" ws "{" ws "\"tool\"" ws ":" ws tool ws "," ws "\"arguments\"" ws ":" ws strobj ws "," ws "\"reason\"" ws ":" ws string ws "}"
        tool ::= \#(toolRule)
        strobj ::= "{" ws (pair (ws "," ws pair)*)? ws "}"
        pair ::= string ws ":" ws string
        plan ::= "\"plan\"" ws ":" ws "[" ws (step (ws "," ws step)*)? ws "]"
        step ::= "{" ws "\"id\"" ws ":" ws string ws "," ws "\"title\"" ws ":" ws string (ws "," ws "\"dependsOn\"" ws ":" ws strarr)? ws "}"
        strarr ::= "[" ws (string (ws "," ws string)*)? ws "]"
        string ::= "\"" char* "\""
        char ::= [^"\\] | "\\" ["\\/bfnrt]
        ws ::= [ \n]?
        """#
    }
}
