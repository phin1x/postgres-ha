#!/bin/bash
#set -ex

_is_sourced() {
	# https://unix.stackexchange.com/a/215279
	[ "${#FUNCNAME[@]}" -ge 2 ] \
		&& [ "${FUNCNAME[0]}" = '_is_sourced' ] \
		&& [ "${FUNCNAME[1]}" = 'source' ]
}

check_non_root() {
	if [ "$(id -u)" = '0' ]; then
		echo "run as root is not allowed"
		exit 1
	fi
}

setup_env() {
	if [ -z $POSTGRES_PASSWORD ]; then
		echo "env var POSTGRES_PASSWORD not set; exiting now"
		exit 1
	fi

	if [ -z $REPMGR_PASSWORD ]; then
		echo "env var REPMGR_PASSWORD not set; exiting now"
		exit 1
	fi

	# this should be defined via dockerfile
	if [ -z $PGDATA ]; then
		echo "env var PGDATA is not set; exiting now"
		exit 1
	fi

	if [ -z $POD_NAME ]; then
		echo "env var POD_NAME is not set; exiting now"
		exit 1
	fi

	if [ -z $HEADLESS_SERVICE ]; then
		echo "env var HEADLESS_SERVICE is not set; exiting now"
		exit 1
	fi

	POSTGRES_USER="${POSTGRES_USER:-postgres}"
	REPMGR_USER="${REPMGR_USER:-repmgr}"
	REPMGR_DATABASE="${REPMGR_DATABASE:-repmgr}"

	PG_CTL_BIN="$(which pg_ctl)"
	REPMGR_BIN="$(which repmgr)"

	export PGPORT=15432

	declare -g DATABASE_ALREADY_EXISTS
	if [ -s "$PGDATA/PG_VERSION" ]; then
		DATABASE_ALREADY_EXISTS='true'
	fi

	declare -g REPMGR_CONFIG_ALREADY_EXISTS
	if [ -s /etc/repmgr/repmgr.conf ]; then
		REPMGR_CONFIG_ALREADY_EXISTS='true'
	fi

	HOME="$(getent passwd $(id -u) | cut -d: -f6)"
}

create_database_directories() {
	local user; user="$(id -u -n)"

	mkdir -p $PGDATA
	chmod 700 $PGDATA

	mkdir -p /var/run/postgresql || :
	chmod 775 /var/run/postgresql || :

	if [ "$user" != "$POSTGRES_USER" ]; then
		find "$PGDATA" \! -user $POSTGRES_USER -exec chown $POSTGRES_USER '{}' +
		find /var/run/postgresql \! -user $POSTGRES_USER -exec chown $POSTGRES_USER '{}' +
	fi

}

init_db() {
	if [ -n "$POSTGRES_INITDB_WALDIR" ]; then
		set -- --waldir "$POSTGRES_INITDB_WALDIR" "$@"
	fi
	
	# remove old data
	rm -rf $PGDATA/*

	eval 'initdb --username="$POSTGRES_USER" --pwfile=<(echo "$POSTGRES_PASSWORD") '"$POSTGRES_INITDB_ARGS"' "$@"'
	if [ $? -ne 0 ]; then
		echo -e "\n###### initdb failed, could not continue #####"
		exit 1
	fi

	{
		echo "listen_addresses = '0.0.0.0'"
		echo "max_wal_senders = 10"
		echo "max_replication_slots = 10"
		echo "wal_level = 'replica'"
		echo "hot_standby = on"
		echo "wal_log_hints = on"
		echo "archive_mode = on"
		echo "archive_command = '/bin/true'"
		echo "shared_preload_libraries = 'repmgr'"
	} >> $PGDATA/postgresql.conf
}

init_hba_conf() {
	{
		echo
		echo "local   replication     $REPMGR_USER                              trust"
		echo "host    replication     $REPMGR_USER      127.0.0.1/32            trust"

		echo "local   $REPMGR_DATABASE          $REPMGR_USER                              trust"
		echo "host    $REPMGR_DATABASE          $REPMGR_USER      127.0.0.1/32            trust"

		echo "host    all             all             all            md5"

	} >> $PGDATA/pg_hba.conf
}

init_repmgr() {
	psql -c "CREATE ROLE $REPMGR_USER ENCRYPTED PASSWORD '$REPMGR_PASSWORD' SUPERUSER CREATEDB CREATEROLE INHERIT LOGIN;"
	createdb --owner=$REPMGR_USER $REPMGR_DATABASE
	psql -c "ALTER USER $REPMGR_USER SET search_path TO repmgr, public;"
}

init_repmgr_conf() {
	if [ "$1" = 'postgres' ]; then
		shift
	fi

	set -- "$@" -p $PGPORT

	{
		echo "node_id=$(get_node_id)"
		echo "node_name='$POD_NAME'"
		echo "conninfo='host=$POD_NAME.$HEADLESS_SERVICE port=15432 user=$REPMGR_USER dbname=$REPMGR_DATABASE connect_timeout=2'"
		echo "data_directory='${PGDATA}'"
		echo "standby_disconnect_on_failover=true"
		echo "primary_visibility_consensus=true"
		echo "reconnect_attempts=4"
		echo "reconnect_interval=4"
		echo "monitor_interval_secs=2"
		echo "connection_check_type='ping'"
		echo "follow_command='$REPMGR_BIN standby follow -f /etc/repmgr/repmgr.conf --upstream-node-id=%n'"
		echo "promote_command='$REPMGR_BIN standby promote -f /etc/repmgr/repmgr.conf'"
		echo "failover='automatic'"
		echo "service_start_command='$PG_CTL_BIN -D \"$PGDATA\" -o \"$(printf '%q ' "$@")\" -w start'"
		echo "service_stop_command='$PG_CTL_BIN -D \"$PGDATA\" -m fast -w stop'"
		echo "service_restart_command='$PG_CTL_BIN -D \"$PGDATA\" -m fast -w restart'"
		echo "service_reload_command='$PG_CTL_BIN -D \"$PGDATA\" -w reload'"
	} > /etc/repmgr/repmgr.conf

}

init_pgpass() {
	local loc="$HOME/.pgpass"
	{
		echo "*:${PGPORT}:replication:${REPMGR_USER}:${REPMGR_PASSWORD}"
		echo "*:${PGPORT}:${REPMGR_DATABASE}:${REPMGR_USER}:${REPMGR_PASSWORD}"
	} > $loc
	chmod 600 $loc
}

init_xinetd() {
	{
		echo "service postgresqlchk"
		echo "{"
		echo "flags = REUSE"
		echo "socket_type = stream"
		echo "wait = no"
		echo "port = 9201"
		echo "server = /scripts/postgresqlchk.sh"
		echo "disable = no"
		echo "only_from = 0.0.0.0/0"
		echo "per_source = UNLIMITED"
		echo "type = UNLISTED"
		echo "user = $(id -u -n)"
		echo "}"
	} > /tmp/xinetd.conf
}

get_node_id() {
	echo "$((${POD_NAME##*-}+1))"
}

start_postgres() {
	if [ "$1" = 'postgres' ]; then
		shift
	fi

	# internal start of server in order to allow setup using psql client
	# does not listen on external TCP/IP and waits until start finishes
	set -- "$@" -p $PGPORT

	PGUSER="${PGUSER:-$POSTGRES_USER}" \
	pg_ctl -D $PGDATA \
		-o "$(printf '%q ' "$@")" \
		-w start
}

register_primary() {
	repmgr -f /etc/repmgr/repmgr.conf primary register $@
}

register_standby() {
	repmgr -f /etc/repmgr/repmgr.conf standby register $@
}

clone_from_primary() {
	repmgr -h $PRIMARY -U repmgr -d repmgr -f /etc/repmgr/repmgr.conf standby clone $@
	if [ $? -ne 0 ]; then
		echo "standby clone failed, could not continue"
		exit 1
	fi
}

get_node_role() {
	for i in 1 2 3; do
		local nodes="$(dig +short +search $HEADLESS_SERVICE)"
		if [ $(echo "$nodes" | wc -l) -eq 0 ] || [ -z $nodes ]; then
			sleep 2
			continue
		else
			for node_ip in $nodes; do
				local primary_conninfo="$(NO_ERRORS=true psql -U repmgr -h $node_ip -tA -c "SELECT conninfo FROM repmgr.show_nodes WHERE (upstream_node_name IS NULL OR upstream_node_name = '') AND active=true;")"
				if [ -z "$primary_conninfo" ]; then
					continue
				fi

				if [ "$(echo $primary_conninfo | wc -l)" -ne 1 ]; then
					echo "cluster have more then one primary, could not continue"
					exit 1
				fi

				echo "node role: we are a standby"
				NODE_ROLE="standby"
				PRIMARY="$(echo "$primary_conninfo" | awk -F 'host=' '{print $2}' | awk '{print $1}')"
				
				return
			done

			echo "no primary found"
		fi
	done

	NODE_ROLE="primary"
	echo "node role: we are the primary"
}

start_repmgrd() {
	repmgrd --daemonize=false -f /etc/repmgr/repmgr.conf &
	REPMGR_PID=$!
}

start_xinetd() {
	xinetd -dontfork -f /tmp/xinetd.conf &
	XINETD_PID=$!
}

stop_all() {
	PGUSER="${PGUSER:-$POSTGRES_USER}" \
        pg_ctl -D "$PGDATA" -w stop

	kill -SIGTERM $REPMGR_PID
	kill -SIGTERM $XINETD_PID
}

_main() {
	check_non_root
	setup_env
	create_database_directories
	init_pgpass
	init_xinetd
	get_node_role

	if [ -z "$REPMGR_CONFIG_ALREADY_EXISTS" ]; then
		init_repmgr_conf "$@"
	fi

	if [ -z "$DATABASE_ALREADY_EXISTS" ]; then
		if [ "$NODE_ROLE" = "primary" ]; then
			init_db
			init_hba_conf
			start_postgres "$@"
			init_repmgr
			register_primary
		else
			clone_from_primary
			start_postgres "$@"
			register_standby
		fi
	else
		if [ "$NODE_ROLE" = "standby" ]; then
			# we don't want to create a fresh clone
			clone_from_primary --replication-conf-only
			start_postgres "$@"
			# --force overwrites the current node data in the database
			register_standby --force
		else
			start_postgres "$@"
		fi
	fi

	start_repmgrd
	start_xinetd

	trap stop_postgres_and_repmgr SIGTERM SIGINT

	wait $REPMGR_PID $XINETD_PID
}

if ! _is_sourced; then
	_main "$@"
fi
