defmodule Ravix.Factory do
  use ExMachina

  alias Ravix.Documents.{Session, Conventions}
  alias Ravix.Connection.{ServerNode, Topology, NodeSelector}
  alias Ravix.Connection.Network.State, as: NetworkState

  def session_document_factory do
    random_entity = %{id: UUID.uuid4(), something: Faker.Cat.breed()}

    %Session.SessionDocument{
      entity: random_entity,
      key: UUID.uuid4(),
      change_vector: "A:150-fGrQ73YexEqvOBc/0RrYUA",
      metadata: %{
        "@collection": "@empty",
        "@last-modified": "2022-01-24T08:35:28.5915575Z"
      }
    }
  end

  def session_state_factory do
    random_document_id = UUID.uuid4()
    random_deleted_entity = %{id: UUID.uuid4(), something: Faker.Cat.breed()}

    %Session.State{
      session_id: UUID.uuid4(),
      database: Faker.Cat.name(),
      documents_by_id: Map.put(%{}, random_document_id, build(:session_document)),
      defer_commands: [%{key: UUID.uuid4()}],
      deleted_entities: [random_deleted_entity],
      number_of_requests: Enum.random(0..100)
    }
  end

  def server_node_healthy_factory do
    %ServerNode{
      url: Faker.Internet.url(),
      port: Enum.random(1024..65535),
      protocol: :http,
      database: "test",
      status: :healthy
    }
  end

  def server_node_unhealthy_factory do
    %ServerNode{
      url: Faker.Internet.url(),
      port: Enum.random(1024..65535),
      protocol: :http,
      database: "test",
      status: :unhealthy
    }
  end

  def topology_factory do
    %Topology{
      etag: Faker.Internet.slug(),
      nodes: [build(:server_node_healthy), build(:server_node_unhealthy)]
    }
  end

  def conventions_factory do
    %Conventions{
      max_number_of_requests_per_session: Enum.random(10..50),
      max_ids_to_catch: Enum.random(128..1024),
      timeout: 1000,
      max_length_of_query_using_get_url: Enum.random(128..1024)
    }
  end

  def network_state_factory do
    %NetworkState{
      database_name: "test",
      certificate: "test" |> Base.encode64(),
      certificate_file: nil,
      node_selector: %NodeSelector{
        current_node_index: 1,
        topology: build(:topology)
      },
      conventions: build(:conventions)
    }
  end
end
