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
        if [ -z $PGPOOL_USERNAME ]; then
                echo "env var POSTGRES_PASSWORD not set; exiting now"
                exit 1
        fi

        if [ -z $PGPOOL_PASSWORD ]; then
                echo "env var REPMGR_PASSWORD not set; exiting now"
                exit 1
        fi

        if [ -z $CLUSTER_NETWORK_CIDR ]; then
                echo "env var CLUSTER_NETWORK_CIDR not set; exiting now"
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

	if [ -z $NUM_NODES ]; then
		echo "env var NUM_NODES is not set; exiting now"
		exit 1
	fi

        POSTGRES_USER="${POSTGRES_USER:-postgres}"

        export PGPORT=15432

	HOME="$(getent passwd $(id -u) | cut -d: -f6)"
}

init_pgpass() {
        local loc="$HOME/.pgpass"
        {
                echo "*:${PGPORT}:*:${POSTGRES_USER}:${POSTGRES_PASSWORD}"
        } > $loc
        chmod 600 $loc
}

init_hba_conf() {
        {
		echo "local   all             all             all            trust"
                echo "host    all             all             all            md5"

        } >> $HOME/hba.conf
}

init_pgpool() {
	{
		echo "listen_addresses = '*'"
		echo "port = 5432"
		echo "socket_dir = /tmp"
		echo "pcp_socket_dir = /tmp"
		echo "max_pool = 15"
		echo "enable_pool_hba = on"
		echo "load_balance_mode = off"
		echo "replication = off"
		echo "pool_passwd = '$HOME/pool_password'"
		echo "allow_clear_text_frontend_auth = off"
		echo "authentication_timeout = 30"
		echo "black_function_list = 'nextval,setval'"
		echo "health_check_period = 30"
		echo "health_check_timeout = 10"
		echo "health_check_user = '$POSTGRES_USER'"
		#echo "health_check_password = ''"
		echo "health_check_max_retries = 5"
		echo "health_check_retry_delay = 5"


		local podNameTpl=${POD_NAME%-*}
		for ((i=0; i<$NUM_NODES; i++)); do echo $i; done
			echo "backend_hostname${i} = '$podNameTpl${i}.$CLUSTER_DOMAIN'"
			echo "backend_port${i} = 15432"
			echo "backend_weight${i} = 100"
		done

	} > $HOME/pgpool.conf

	 pg_md5 -m --config-file="$HOME/pgpool.conf" -u "$PGPOOL_USERNAME" "$PGPOOL_PASSWORD"	
}

start_pgpool() {
	pgpool --config-file=$HOME/pgpool.conf --hba-file=$HOME/hba.conf
}

_main() {
        check_non_root
        setup_env
        init_pgpass
        init_pgpool

	start_pgpool
}

if ! _is_sourced; then
        _main "$@"
fi
