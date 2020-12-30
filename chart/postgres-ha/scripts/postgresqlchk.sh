#!/bin/bash
 
export PGPORT='15432'
export PGCONNECT_TIMEOUT=10
 
SLAVE_CHECK="SELECT pg_is_in_recovery()"
WRITABLE_CHECK="SHOW transaction_read_only"
 
return_ok()
{
    echo -ne "HTTP/1.1 200 OK\r\n"
    echo -ne "Content-Length: $(echo -n "$1" | wc -c)\r\n"
    echo -ne "Content-Type: text/plain\r\n"
    echo -ne "\r\n"
    echo -ne "$1"
    echo -ne "\r\n"
 
    exit 0
}
 
return_fail()
{
    echo -ne "HTTP/1.1 503 Service Unavailable\r\n"
    echo -ne "Content-Length: 4\r\n"
    echo -ne "Content-Type: text/plain\r\n"
    echo -ne "\r\n"
    echo -ne "down"
    echo -ne "\r\n"
 
    exit 1
}
 
SLAVE=$(psql -qt -c "$SLAVE_CHECK" 2>/dev/null)
if [ $? -ne 0 ]; then
    return_fail
elif [ $SLAVE == "t" ]; then
    return_ok "slave"
fi
 
READONLY=$(psql -qt -c "$WRITABLE_CHECK" 2>/dev/null)
if [ $? -ne 0 ]; then
    return_fail
elif [ $READONLY == "off" ]; then
    return_ok "master"
fi
 
return_ok "single";
