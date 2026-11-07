import unittest

from Windows.DongVPN import build_xray_config, parse_vless


PROFILE = ('vless://1c8403a8-fc3d-4a1a-9542-23d1cba856fa@198.51.100.42:443'
           '?encryption=none&flow=xtls-rprx-vision&security=reality&sni=aws.amazon.com'
           '&fp=chrome&pbk=public-key&sid=01020304&type=tcp#Hong-Kong')


class VlessProfileTests(unittest.TestCase):
    def test_parses_supported_reality_profile(self):
        connection = parse_vless(PROFILE)
        self.assertEqual(connection['server'], '198.51.100.42')
        self.assertEqual(connection['port'], 443)
        self.assertEqual(connection['flow'], 'xtls-rprx-vision')
        self.assertEqual(connection['name'], 'Hong-Kong')

    def test_config_has_loopback_proxy_and_reality_outbound(self):
        config = build_xray_config(parse_vless(PROFILE), 10809)
        inbound = config['inbounds'][0]
        outbound = config['outbounds'][0]
        self.assertEqual((inbound['listen'], inbound['port'], inbound['protocol']), ('127.0.0.1', 10809, 'http'))
        self.assertEqual(outbound['protocol'], 'vless')
        self.assertEqual(outbound['streamSettings']['security'], 'reality')
        reality = outbound['streamSettings']['realitySettings']
        self.assertEqual(reality['password'], 'public-key')
        self.assertNotIn('publicKey', reality)

    def test_rejects_other_protocols(self):
        with self.assertRaises(ValueError):
            parse_vless('https://example.com/profile')

    def test_rejects_missing_reality_fields(self):
        with self.assertRaises(ValueError):
            parse_vless('vless://id@example.com:443?security=reality&type=tcp')


if __name__ == '__main__':
    unittest.main()
