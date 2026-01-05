import Foundation

// MARK: - Search API Models

/// Request body for Perplexity Search API
struct PerplexitySearchRequest: Codable {
    let query: String
    let max_results: Int?
    let max_tokens: Int?
    let search_recency_filter: String?
    
    init(
        query: String,
        maxResults: Int = 10,
        maxTokens: Int = 25000,
        recencyFilter: String? = nil
    ) {
        self.query = query
        self.max_results = maxResults
        self.max_tokens = maxTokens
        self.search_recency_filter = recencyFilter
    }
}

/// Response from Perplexity Search API
struct PerplexitySearchResponse: Codable {
    let results: [SearchResult]
    
    struct SearchResult: Codable {
        let title: String
        let url: String
        let snippet: String
        let date: String?
        let last_updated: String?
    }
}

enum PerplexityError: Error, LocalizedError {
    case invalidResponse
    case httpError(Int, String?)
    case noResults
    case apiKeyMissing
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Perplexity API"
        case .httpError(let code, let message):
            if let message = message {
                return "Perplexity API error: HTTP \(code) - \(message)"
            }
            return "Perplexity API error: HTTP \(code)"
        case .noResults:
            return "No results from Perplexity search"
        case .apiKeyMissing:
            return "Perplexity API key not configured"
        }
    }
}

/// Service for fetching web search results via Perplexity Search API
actor PerplexityService {
    private let baseURL = URL(string: "https://api.perplexity.ai/search")!
    
    /// Searches the web for relevant context based on the user's query
    /// Returns formatted search results, or nil if the API key is not set
    func searchForContext(query: String, apiKey: String) async throws -> String? {
        guard !apiKey.isEmpty else {
            return nil // Silently skip if no API key
        }
        
        AppLog.shared.log("Perplexity search started for query: \(query.prefix(50))...")
        
        let requestBody = PerplexitySearchRequest(
            query: query,
            maxResults: 5,
            maxTokens: 10000,
            recencyFilter: nil
        )
        
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PerplexityError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8)
            AppLog.shared.log("Perplexity HTTP error: \(httpResponse.statusCode) - \(errorMessage ?? "unknown")", level: .error)
            throw PerplexityError.httpError(httpResponse.statusCode, errorMessage)
        }
        
        let searchResponse = try JSONDecoder().decode(PerplexitySearchResponse.self, from: data)
        
        guard !searchResponse.results.isEmpty else {
            AppLog.shared.log("Perplexity search returned no results")
            return nil
        }
        
        // Format the search results as context for the model
        let formattedResults = formatSearchResults(searchResponse.results)
        
        AppLog.shared.log("Perplexity search completed (results: \(searchResponse.results.count))")
        return formattedResults
    }
    
    /// Formats search results into a readable context string for the model
    private func formatSearchResults(_ results: [PerplexitySearchResponse.SearchResult]) -> String {
        var context = "Web Search Results:\n\n"
        
        for (index, result) in results.enumerated() {
            context += "[\(index + 1)] \(result.title)\n"
            context += "URL: \(result.url)\n"
            context += "\(result.snippet)\n"
            if let date = result.last_updated ?? result.date {
                context += "Updated: \(date)\n"
            }
            context += "\n"
        }
        
        return context
    }
}
