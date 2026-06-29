#!/bin/bash
set -e

echo "== Mengatur Nextcloud Domain =="

until php /var/www/html/occ status >/dev/null 2>&1
do
    sleep 5
done

php /var/www/html/occ config:system:set trusted_domains 0 --value="${NEXTCLOUD_DOMAIN}"

php /var/www/html/occ config:system:set overwritehost --value="${NEXTCLOUD_DOMAIN}"

php /var/www/html/occ config:system:set overwriteprotocol --value="${NEXTCLOUD_PROTOCOL}"

echo "== Domain berhasil diatur =="