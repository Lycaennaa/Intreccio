import Foundation

nonisolated enum GitProcessEnvironment {
    private static let inheritedRepositoryContextVariables = [
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_COMMON_DIR",
        "GIT_INDEX_FILE",
        "GIT_NAMESPACE",
        "GIT_PREFIX",
        "GIT_CEILING_DIRECTORIES"
    ]

    static func prepare(inherited: [String: String], overrides: [String: String]) -> [String: String] {
        var environment = inherited
        for key in inheritedRepositoryContextVariables {
            environment.removeValue(forKey: key)
        }
        environment.merge(overrides) { _, new in new }
        return environment
    }
}
