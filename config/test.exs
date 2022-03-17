import Config

config :ravix,
  urls: [System.get_env("RAVENDB_URL", "http://localhost:8080")],
  database: "default",
  retry_on_failure: true,
  retry_backoff: 100,
  retry_count: 3,
  document_conventions: %{
    max_number_of_requests_per_session: 30,
    max_ids_to_catch: 32,
    timeout: 30,
    use_optimistic_concurrency: false,
    max_length_of_query_using_get_url: 1024 + 512,
    identity_parts_separator: "/",
    disable_topology_update: false
  }
