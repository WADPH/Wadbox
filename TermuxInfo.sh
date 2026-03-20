echo "__________________________________________"
echo "         ";
echo "WiFi Info";
echo "         ";


termux-wifi-connectioninfo | grep -E 'ip|ssid|rssi|bssid' | grep -v 'bssid'
echo "__________________________________________":
echo "         ";
echo "Battery Info";
echo "            ";
termux-battery-status | grep -E 'health|status|temperature|percentage';
echo "__________________________________________";
