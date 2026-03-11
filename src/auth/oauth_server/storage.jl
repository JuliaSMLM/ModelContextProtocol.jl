# src/auth/oauth_server/storage.jl
# Token and authorization code storage interface and implementations

using Dates: DateTime, now, UTC

# Storage interface methods (to be implemented by concrete types)

"""
    store_pending!(storage::TokenStorage, pending::PendingAuthorization)

Store a pending authorization request.
The pending authorization is keyed by its `upstream_state` field.
"""
function store_pending! end

"""
    get_pending(storage::TokenStorage, upstream_state::AbstractString) -> Union{PendingAuthorization,Nothing}

Retrieve a pending authorization by upstream state.
Returns `nothing` if not found or expired.
"""
function get_pending end

"""
    delete_pending!(storage::TokenStorage, upstream_state::AbstractString)

Delete a pending authorization after use or expiration.
"""
function delete_pending! end

"""
    store_auth_code!(storage::TokenStorage, auth_code::AuthorizationCode)

Store an authorization code.
"""
function store_auth_code! end

"""
    get_auth_code(storage::TokenStorage, code::AbstractString) -> Union{AuthorizationCode,Nothing}

Retrieve an authorization code.
Returns `nothing` if not found or expired.
"""
function get_auth_code end

"""
    delete_auth_code!(storage::TokenStorage, code::AbstractString)

Delete an authorization code after use.
Authorization codes are single-use per OAuth spec.
"""
function delete_auth_code! end

"""
    store_token!(storage::TokenStorage, token::IssuedToken)

Store an issued access token.
"""
function store_token! end

"""
    get_token(storage::TokenStorage, access_token::AbstractString) -> Union{IssuedToken,Nothing}

Retrieve an issued token by access token value.
Returns `nothing` if not found or expired.
"""
function get_token end

"""
    delete_token!(storage::TokenStorage, access_token::AbstractString)

Delete/revoke an access token.
"""
function delete_token! end

"""
    get_token_by_refresh(storage::TokenStorage, refresh_token::AbstractString) -> Union{IssuedToken,Nothing}

Retrieve an issued token by its refresh token.
Returns `nothing` if not found or expired.
"""
function get_token_by_refresh end

"""
    cleanup_expired!(storage::TokenStorage)

Remove all expired entries from storage.
Called periodically to prevent unbounded growth.
"""
function cleanup_expired! end

"""
    store_client!(storage::TokenStorage, client::RegisteredClient)

Store a dynamically registered client.
"""
function store_client! end

"""
    get_client(storage::TokenStorage, client_id::AbstractString) -> Union{RegisteredClient,Nothing}

Retrieve a registered client by client ID.
Returns `nothing` if not found.
"""
function get_client end

"""
    delete_client!(storage::TokenStorage, client_id::AbstractString)

Delete a registered client.
"""
function delete_client! end

# ============================================================================
# In-Memory Storage Implementation
# ============================================================================

"""
    InMemoryTokenStorage()

Thread-safe in-memory storage for OAuth tokens and authorization codes.
Suitable for development, testing, and single-instance deployments.

For multi-instance deployments, use a distributed storage backend (Redis, database).
"""
mutable struct InMemoryTokenStorage <: TokenStorage
    pending::Dict{String,PendingAuthorization}
    auth_codes::Dict{String,AuthorizationCode}
    tokens::Dict{String,IssuedToken}
    refresh_index::Dict{String,String}  # refresh_token -> access_token
    clients::Dict{String,RegisteredClient}  # client_id -> RegisteredClient
    lock::ReentrantLock
    pending_ttl::Int  # seconds
end

function InMemoryTokenStorage(; pending_ttl::Int=600)
    InMemoryTokenStorage(
        Dict{String,PendingAuthorization}(),
        Dict{String,AuthorizationCode}(),
        Dict{String,IssuedToken}(),
        Dict{String,String}(),
        Dict{String,RegisteredClient}(),
        ReentrantLock(),
        pending_ttl
    )
end

function Base.show(io::IO, storage::InMemoryTokenStorage)
    lock(storage.lock) do
        print(io, "InMemoryTokenStorage(pending=", length(storage.pending),
              ", codes=", length(storage.auth_codes),
              ", tokens=", length(storage.tokens),
              ", clients=", length(storage.clients), ")")
    end
end

# Pending authorizations

function store_pending!(storage::InMemoryTokenStorage, pending::PendingAuthorization)
    lock(storage.lock) do
        storage.pending[pending.upstream_state] = pending
    end
end

function get_pending(storage::InMemoryTokenStorage, upstream_state::AbstractString)
    lock(storage.lock) do
        pending = get(storage.pending, upstream_state, nothing)
        if isnothing(pending)
            return nothing
        end

        # Check expiration
        elapsed = now(UTC) - pending.created_at
        if elapsed > Second(storage.pending_ttl)
            delete!(storage.pending, upstream_state)
            return nothing
        end

        return pending
    end
end

function delete_pending!(storage::InMemoryTokenStorage, upstream_state::AbstractString)
    lock(storage.lock) do
        delete!(storage.pending, upstream_state)
    end
end

# Authorization codes

function store_auth_code!(storage::InMemoryTokenStorage, auth_code::AuthorizationCode)
    lock(storage.lock) do
        storage.auth_codes[auth_code.code] = auth_code
    end
end

function get_auth_code(storage::InMemoryTokenStorage, code::AbstractString)
    lock(storage.lock) do
        auth_code = get(storage.auth_codes, code, nothing)
        if isnothing(auth_code)
            return nothing
        end

        # Check expiration
        if now(UTC) > auth_code.expires_at
            delete!(storage.auth_codes, code)
            return nothing
        end

        return auth_code
    end
end

function delete_auth_code!(storage::InMemoryTokenStorage, code::AbstractString)
    lock(storage.lock) do
        delete!(storage.auth_codes, code)
    end
end

# Access tokens

function store_token!(storage::InMemoryTokenStorage, token::IssuedToken)
    lock(storage.lock) do
        storage.tokens[token.access_token] = token

        # Index by refresh token if present
        if !isnothing(token.refresh_token)
            storage.refresh_index[token.refresh_token] = token.access_token
        end
    end
end

function get_token(storage::InMemoryTokenStorage, access_token::AbstractString)
    lock(storage.lock) do
        token = get(storage.tokens, access_token, nothing)
        if isnothing(token)
            return nothing
        end

        # Check expiration
        if now(UTC) > token.expires_at
            # Don't auto-delete - token might be refreshable
            return nothing
        end

        return token
    end
end

function delete_token!(storage::InMemoryTokenStorage, access_token::AbstractString)
    lock(storage.lock) do
        token = get(storage.tokens, access_token, nothing)
        if !isnothing(token) && !isnothing(token.refresh_token)
            delete!(storage.refresh_index, token.refresh_token)
        end
        delete!(storage.tokens, access_token)
    end
end

function get_token_by_refresh(storage::InMemoryTokenStorage, refresh_token::AbstractString)
    lock(storage.lock) do
        access_token = get(storage.refresh_index, refresh_token, nothing)
        if isnothing(access_token)
            return nothing
        end

        return get(storage.tokens, access_token, nothing)
    end
end

# Cleanup

function cleanup_expired!(storage::InMemoryTokenStorage)
    lock(storage.lock) do
        current_time = now(UTC)

        # Clean pending authorizations
        for (state, pending) in collect(storage.pending)
            if current_time - pending.created_at > Second(storage.pending_ttl)
                delete!(storage.pending, state)
            end
        end

        # Clean authorization codes
        for (code, auth_code) in collect(storage.auth_codes)
            if current_time > auth_code.expires_at
                delete!(storage.auth_codes, code)
            end
        end

        # Clean tokens (keep expired tokens with valid refresh tokens for a grace period)
        # For simplicity, we just check access token expiration
        # In production, you'd want more sophisticated refresh token handling
        for (access_token, token) in collect(storage.tokens)
            if current_time > token.expires_at
                # If no refresh token, delete immediately
                if isnothing(token.refresh_token)
                    delete!(storage.tokens, access_token)
                end
                # With refresh token, keep for refresh_token_ttl from original issue
                # (simplified: we'd need to track refresh token expiry separately)
            end
        end
    end
end

"""
    token_count(storage::InMemoryTokenStorage) -> Int

Return the number of stored tokens. Useful for monitoring.
"""
function token_count(storage::InMemoryTokenStorage)
    lock(storage.lock) do
        return length(storage.tokens)
    end
end

"""
    pending_count(storage::InMemoryTokenStorage) -> Int

Return the number of pending authorizations. Useful for monitoring.
"""
function pending_count(storage::InMemoryTokenStorage)
    lock(storage.lock) do
        return length(storage.pending)
    end
end

# Registered clients (DCR)

function store_client!(storage::InMemoryTokenStorage, client::RegisteredClient)
    lock(storage.lock) do
        storage.clients[client.client_id] = client
    end
end

function get_client(storage::InMemoryTokenStorage, client_id::AbstractString)
    lock(storage.lock) do
        return get(storage.clients, client_id, nothing)
    end
end

function delete_client!(storage::InMemoryTokenStorage, client_id::AbstractString)
    lock(storage.lock) do
        delete!(storage.clients, client_id)
    end
end

"""
    client_count(storage::InMemoryTokenStorage) -> Int

Return the number of registered clients. Useful for monitoring.
"""
function client_count(storage::InMemoryTokenStorage)
    lock(storage.lock) do
        return length(storage.clients)
    end
end
