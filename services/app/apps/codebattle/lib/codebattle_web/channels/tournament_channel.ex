defmodule CodebattleWeb.TournamentChannel do
  @moduledoc false
  use CodebattleWeb, :channel

  require Logger

  alias Codebattle.Tournament
  alias Codebattle.Tournament.Helpers

  def join("tournament:" <> tournament_id, payload, socket) do
    current_user = socket.assigns.current_user

    with tournament when not is_nil(tournament) <-
           Tournament.Context.get_tournament_info(tournament_id),
         true <- Helpers.can_access?(tournament, current_user, payload) do
      mark_player_as_online(tournament, current_user)

      payload =
        tournament
        |> subscribe_on_tournament_events(socket)
        |> get_tournament_join_payload(socket)

      {:ok, payload,
       assign(socket,
         tournament_info:
           Map.take(tournament, [:id, :players_table, :matches_table, :tasks_table])
       )}
    else
      _ ->
        {:error, %{reason: "not_found"}}
    end
  end

  def handle_in("tournament:join", %{"team_id" => team_id}, socket) do
    tournament_id = socket.assigns.tournament_info.id

    Tournament.Context.handle_event(tournament_id, :join, %{
      user: socket.assigns.current_user,
      team_id: to_string(team_id)
    })

    {:noreply, socket}
  end

  def handle_in("tournament:join", _, socket) do
    tournament_id = socket.assigns.tournament_info.id

    Tournament.Context.handle_event(tournament_id, :join, %{
      user: socket.assigns.current_user
    })

    {:noreply, socket}
  end

  def handle_in("tournament:leave", %{"team_id" => team_id}, socket) do
    tournament_id = socket.assigns.tournament_info.id

    Tournament.Context.handle_event(tournament_id, :leave, %{
      user_id: socket.assigns.current_user.id,
      team_id: to_string(team_id)
    })

    {:noreply, socket}
  end

  def handle_in("tournament:leave", _, socket) do
    tournament_id = socket.assigns.tournament_info.id

    Tournament.Context.handle_event(tournament_id, :leave, %{
      user_id: socket.assigns.current_user.id
    })

    {:noreply, socket}
  end

  def handle_in("tournament:kick", %{"user_id" => user_id}, socket) do
    tournament_id = socket.assigns.tournament_info.id
    tournament = Tournament.Server.get_tournament(tournament_id)

    if Helpers.can_moderate?(tournament, socket.assigns.current_user) do
      Tournament.Context.handle_event(tournament_id, :leave, %{
        user_id: String.to_integer(user_id)
      })
    end

    {:noreply, socket}
  end

  def handle_in("tournament:restart", _, socket) do
    tournament_id = socket.assigns.tournament_info.id
    tournament = Tournament.Context.get!(tournament_id)

    if Helpers.can_moderate?(tournament, socket.assigns.current_user) do
      Tournament.Context.restart(tournament)

      Tournament.Context.handle_event(tournament_id, :restart, %{
        user: socket.assigns.current_user
      })

      tournament = Tournament.Context.get!(tournament_id)
      broadcast!(socket, "tournament:restarted", %{tournament: tournament})
    end

    {:noreply, socket}

    {:noreply, socket}
  end

  def handle_in("tournament:open_up", _, socket) do
    tournament_id = socket.assigns.tournament_info.id

    Tournament.Context.handle_event(tournament_id, :open_up, %{
      user: socket.assigns.current_user
    })

    {:noreply, socket}
  end

  def handle_in("tournament:cancel", _, socket) do
    tournament_id = socket.assigns.tournament_info.id
    tournament = Tournament.Server.get_tournament(tournament_id)

    if Helpers.can_moderate?(tournament, socket.assigns.current_user) do
      Tournament.Context.handle_event(tournament_id, :cancel, %{
        user: socket.assigns.current_user
      })
    end

    {:noreply, socket}
  end

  def handle_in("tournament:start", _, socket) do
    tournament_id = socket.assigns.tournament_info.id
    tournament = Tournament.Server.get_tournament(tournament_id)

    if Helpers.can_moderate?(tournament, socket.assigns.current_user) do
      Tournament.Context.handle_event(tournament_id, :start, %{
        user: socket.assigns.current_user
      })
    end

    {:noreply, socket}
  end

  def handle_in("tournament:start_round", _, socket) do
    tournament_id = socket.assigns.tournament_info.id
    tournament = Tournament.Server.get_tournament(tournament_id)

    if Helpers.can_moderate?(tournament, socket.assigns.current_user) do
      Tournament.Context.handle_event(tournament_id, :stop_round_break, %{})
    end

    {:noreply, socket}
  end

  def handle_in("tournament:matches:request", %{"player_id" => id}, socket) do
    tournament_info = socket.assigns.tournament_info
    matches = Helpers.get_matches_by_players(tournament_info, [id])

    {:reply, {:ok, %{matches: matches}}, socket}
  end

  def handle_in(
        "tournament:players:paginated",
        %{"page_num" => id, "page_size" => page_size},
        socket
      ) do
    tournament_info = socket.assigns.tournament_info
    players = Helpers.get_paginated_players(tournament_info, min(id, 1000), min(page_size, 30))
    {:reply, {:ok, %{players: players}}, socket}
  end

  # def handle_in("tournament:subscribe_players", %{"player_ids" => player_ids}, socket) do
  #   tournament_id = socket.assigns.tournament_info.id

  #   Enum.each(player_ids, fn player_id ->
  #     Codebattle.PubSub.subscribe("tournament_player:#{tournament_id}_#{player_id}")
  #   end)

  #   {:reply, {:ok, %{}}, socket}
  # end

  def handle_info(%{event: "tournament:updated", payload: payload}, socket) do
    matches =
      if payload.tournament.type in ["swiss", "ladder"] do
        []
      else
        Helpers.get_matches(payload.tournament)
      end

    push(socket, "tournament:update", %{
      tournament:
        Map.drop(payload.tournament, [
          :__struct__,
          :__meta__,
          :creator,
          :players,
          :matches,
          :players_table,
          :matches_table,
          :tasks_table,
          :round_tasks,
          :played_pair_ids
        ]),
      players: Helpers.get_top_players(payload.tournament),
      matches: matches
    })

    {:noreply, socket}
  end

  def handle_info(%{event: "tournament:match:upserted", payload: payload}, socket) do
    push(socket, "tournament:match:upserted", %{match: payload.match, players: payload.players})

    {:noreply, socket}
  end

  def handle_info(%{event: "tournament:round_created", payload: payload}, socket) do
    push(socket, "tournament:round_created", %{tournament: payload.tournament})

    {:noreply, socket}
  end

  def handle_info(%{event: "tournament:round_finished", payload: payload}, socket) do
    push(socket, "tournament:round_finished", %{
      tournament: payload.tournament,
      players: payload.players
    })

    {:noreply, socket}
  end

  def handle_info(%{event: "tournament:finished"}, socket) do
    push(socket, "tournament:finished", %{
      tournament: %{
        state: "finished"
      }
    })

    {:noreply, socket}
  end

  def handle_info(%{event: "tournament:player:joined", payload: payload}, socket) do
    push(socket, "tournament:player:joined", payload)

    {:noreply, socket}
  end

  def handle_info(%{event: "tournament:player:left", payload: payload}, socket) do
    push(socket, "tournament:player:left", payload)

    {:noreply, socket}
  end

  def handle_info(message, socket) do
    Logger.warning("Unexpected message: " <> inspect(message))
    {:noreply, socket}
  end

  defp subscribe_on_tournament_events(tournament, socket) do
    current_user = socket.assigns.current_user

    Codebattle.PubSub.subscribe("tournament:#{tournament.id}:player:#{current_user.id}")

    if Helpers.can_moderate?(tournament, current_user) do
      Codebattle.PubSub.subscribe("tournament:#{tournament.id}")
    else
      Codebattle.PubSub.subscribe("tournament:#{tournament.id}:common")
    end

    tournament
  end

  defp get_tournament_join_payload(%{type: type} = tournament, socket)
       when type in ["swiss", "ladder", "stairway"] do
    current_user = socket.assigns.current_user

    {matches, players} =
      if Helpers.can_moderate?(tournament, current_user) do
        {Helpers.get_matches(tournament),
         [Helpers.get_player(tournament, current_user.id)] ++
           Helpers.get_paginated_players(tournament, 0, 30)}
      else
        {Helpers.get_matches_by_players(tournament, [current_user.id]),
         [Helpers.get_player(tournament, current_user.id)] ++
           Helpers.get_top_players(tournament)}
      end

    %{
      tournament: Map.drop(tournament, [:players_table, :matches_table, :tasks_table]),
      matches: matches,
      players: players
    }
  end

  defp get_tournament_join_payload(tournament, _socket) do
    %{
      tournament: Map.drop(tournament, [:players_table, :matches_table, :tasks_table]),
      matches: Helpers.get_matches(tournament),
      players: Helpers.get_players(tournament)
    }
  end

  defp mark_player_as_online(tournament, current_user) do
    case Tournament.Players.get_player(tournament, current_user.id) do
      %{was_online: false} = player ->
        Tournament.Players.put_player(tournament, %{player | was_online: true})

      _ ->
        :noop
    end
  end
end
