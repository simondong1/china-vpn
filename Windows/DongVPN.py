import json
import os
import queue
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid
import webbrowser
import winreg
from pathlib import Path
from tkinter import StringVar, Tk, messagebox, ttk

import certifi
import requests
from requests.adapters import HTTPAdapter


APP_TITLE = 'Dong VPN'
PROXY_PORTS = range(10809, 10910)
REGISTRY_PATH = r'Software\Microsoft\Windows\CurrentVersion\Internet Settings'
SUPPORT_EMAIL = 'simondong0919@gmail.com'


def resource_path(name):
    root = Path(getattr(sys, '_MEIPASS', Path(__file__).resolve().parent))
    return root / name


def data_path():
    override = os.environ.get('DONGVPN_DATA_DIR')
    if override:
        path = Path(override)
    else:
        path = Path(os.environ.get('LOCALAPPDATA', Path.home())) / 'DongVPN'
    path.mkdir(parents=True, exist_ok=True)
    return path


DATA = data_path()
STATE_FILE = DATA / 'state.json'
CONFIG_FILE = DATA / 'xray-config.json'


def read_private_json(filename):
    path = resource_path(filename)
    return json.loads(path.read_text(encoding='utf-8')) if path.exists() else None


def parse_vless(link):
    parsed = urllib.parse.urlsplit(link.strip())
    if parsed.scheme != 'vless' or not parsed.username or not parsed.hostname or not parsed.port:
        raise ValueError('This server profile is not a complete VLESS link.')
    params = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
    get = lambda name, default='': params.get(name, [default])[0]
    if get('security') != 'reality' or get('type', 'tcp') != 'tcp':
        raise ValueError('Dong VPN requires a VLESS + REALITY TCP profile.')
    if not get('pbk') or not get('sid') or not get('sni'):
        raise ValueError('The server profile is missing REALITY parameters.')
    return {
        'server': parsed.hostname,
        'port': parsed.port,
        'uuid': urllib.parse.unquote(parsed.username),
        'flow': get('flow'),
        'sni': get('sni'),
        'fingerprint': get('fp', 'chrome'),
        'publicKey': get('pbk'),
        'shortID': get('sid'),
        'name': urllib.parse.unquote(parsed.fragment) or 'DongVPN',
    }


def build_xray_config(connection, proxy_port):
    rules = [{
        'type': 'field', 'outboundTag': 'direct',
        'ip': ['10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16',
               '172.16.0.0/12', '192.168.0.0/16', '::1/128', 'fc00::/7', 'fe80::/10'],
    }]
    if resource_path('geoip.dat').exists():
        rules.append({'type': 'field', 'outboundTag': 'direct', 'ip': ['geoip:cn']})
    if resource_path('geosite.dat').exists():
        rules.append({'type': 'field', 'outboundTag': 'direct', 'domain': ['geosite:cn']})
    return {
        'log': {'loglevel': 'warning'},
        'inbounds': [{'listen': '127.0.0.1', 'port': proxy_port, 'protocol': 'http'}],
        'routing': {'domainStrategy': 'AsIs', 'rules': rules},
        'outbounds': [{
            'tag': 'proxy', 'protocol': 'vless',
            'settings': {'vnext': [{
                'address': connection['server'], 'port': connection['port'],
                'users': [{'id': connection['uuid'], 'encryption': 'none', 'flow': connection['flow']}],
            }]},
            'streamSettings': {
                'network': 'tcp', 'security': 'reality',
                'realitySettings': {
                    'serverName': connection['sni'], 'fingerprint': connection['fingerprint'],
                    'password': connection['publicKey'], 'shortId': connection['shortID'],
                },
            },
        }, {'tag': 'direct', 'protocol': 'freedom'}],
    }


def available_proxy_port():
    for port in PROXY_PORTS:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
            try:
                server.bind(('127.0.0.1', port))
                return port
            except OSError:
                continue
    raise RuntimeError('No local proxy port is available. Close other proxy applications and retry.')


def registry_read(name):
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, REGISTRY_PATH) as key:
        try:
            return winreg.QueryValueEx(key, name)
        except FileNotFoundError:
            return None


def registry_write(name, value, value_type):
    with winreg.CreateKey(winreg.HKEY_CURRENT_USER, REGISTRY_PATH) as key:
        if value is None:
            try:
                winreg.DeleteValue(key, name)
            except FileNotFoundError:
                pass
        else:
            winreg.SetValueEx(key, name, 0, value_type, value)


def refresh_windows_proxy():
    import ctypes
    ctypes.windll.Wininet.InternetSetOptionW(0, 39, 0, 0)
    ctypes.windll.Wininet.InternetSetOptionW(0, 37, 0, 0)


class DongVPN:
    def __init__(self, root):
        self.root = root
        self.root.title(APP_TITLE)
        self.root.geometry('450x242')
        self.root.minsize(420, 242)
        self.root.maxsize(600, 300)
        self.root.protocol('WM_DELETE_WINDOW', self.close)
        self.queue = queue.Queue()
        self.cancel_event = threading.Event()
        self.heartbeat_stop = threading.Event()
        self.worker = None
        self.activity = 'disconnected'
        self.pending_profile = None
        self.process = None
        self.remote_lease = False
        self.connection = None
        self.proxy_port = None
        self.profile_name = StringVar()
        self.status = StringVar(value='Disconnected')
        self.ip = StringVar(value='')
        self.button_text = StringVar(value='Connect')
        self.profiles = {}
        self.control = read_private_json('hk-control.json') or {}
        self.client_id = self._client_id()
        self._load_profiles()
        self._build_ui()
        self.root.after(150, self._drain_queue)
        self._recover_proxy_if_needed()

    def _client_id(self):
        try:
            state = json.loads(STATE_FILE.read_text(encoding='utf-8'))
            return state['clientId']
        except (OSError, ValueError, KeyError):
            value = str(uuid.uuid4())
            STATE_FILE.write_text(json.dumps({'clientId': value}, indent=2) + '\n', encoding='utf-8')
            return value

    def _load_profiles(self):
        for name, filename in (('US West (Oregon)', 'oregon.vless'), ('Hong Kong', 'hong-kong.vless')):
            path = resource_path(filename)
            if path.exists():
                link = path.read_text(encoding='utf-8').strip()
                if link:
                    self.profiles[name] = link
        if not self.profiles:
            raise RuntimeError('No DongVPN server profile is bundled in this build.')
        self.profile_name.set(next(iter(self.profiles)))

    def _build_ui(self):
        frame = ttk.Frame(self.root, padding=(22, 18, 22, 16))
        frame.pack(fill='both', expand=True)
        heading = ttk.Label(frame, text='Dong VPN', font=('Segoe UI', 17, 'bold'))
        heading.pack(anchor='w')

        row = ttk.Frame(frame)
        row.pack(fill='x', pady=(17, 8))
        ttk.Label(row, text='Server').pack(side='left')
        self.server = ttk.Combobox(row, textvariable=self.profile_name, values=list(self.profiles),
                                   state='readonly', width=24)
        self.server.pack(side='right')

        status_row = ttk.Frame(frame)
        status_row.pack(fill='x', pady=(6, 10))
        self.status_label = ttk.Label(status_row, textvariable=self.status, font=('Segoe UI', 10, 'bold'))
        self.status_label.pack(side='left')
        ttk.Label(status_row, textvariable=self.ip).pack(side='right')

        self.button = ttk.Button(frame, textvariable=self.button_text, command=self.toggle)
        self.button.pack(fill='x', ipady=5, pady=(5, 8))
        ttk.Button(frame, text='Email support', command=self.email_support).pack(anchor='e')
        self.server.bind('<<ComboboxSelected>>', self.change_profile)

    def _drain_queue(self):
        try:
            while True:
                action, value = self.queue.get_nowait()
                if action == 'status':
                    self.status.set(value)
                elif action == 'connected':
                    self.activity = 'connected'
                    self.status.set('Connected')
                    self.ip.set(value)
                    self.button_text.set('Disconnect')
                    self.server.configure(state='disabled')
                    self.status_label.configure(foreground='#16834a')
                elif action == 'disconnected':
                    self.activity = 'disconnected'
                    self.status.set('Disconnected')
                    self.ip.set('')
                    self.button_text.set('Connect')
                    self.server.configure(state='readonly')
                    self.status_label.configure(foreground='')
                elif action == 'failed':
                    self.activity = 'disconnected'
                    self.status.set('Connection failed')
                    self.ip.set('')
                    self.button_text.set('Connect')
                    self.server.configure(state='readonly')
                    self.status_label.configure(foreground='#b3261e')
                    messagebox.showerror('Dong VPN could not connect',
                                         f'{value}\n\nPlease email {SUPPORT_EMAIL} for help.')
                elif action == 'button':
                    self.button_text.set(value)
                elif action == 'button_state':
                    self.button.configure(state=value)
        except queue.Empty:
            pass
        self.root.after(150, self._drain_queue)

    def _set_status(self, value):
        self.queue.put(('status', value))

    def toggle(self):
        if self.activity == 'connecting':
            self.cancel_event.set()
            self.button.configure(state='disabled')
            self.queue.put(('button', 'Stopping...'))
            return
        if self.activity == 'connected':
            self.activity = 'disconnecting'
            self.button.configure(state='disabled')
            self.worker = threading.Thread(target=self._disconnect_worker, daemon=True)
            self.worker.start()
            return
        if self.activity != 'disconnected':
            return
        self.cancel_event.clear()
        self.heartbeat_stop.clear()
        self.activity = 'connecting'
        self.pending_profile = self.profile_name.get()
        self.server.configure(state='disabled')
        self.button.configure(state='normal')
        self.button_text.set('Cancel')
        self.worker = threading.Thread(target=self._connect_worker, daemon=True)
        self.worker.start()

    def change_profile(self, _event=None):
        if self.activity != 'disconnected':
            return

    def _request_control(self, route, method='POST', timeout=12):
        if not self.control.get('url') or not self.control.get('token'):
            raise RuntimeError('Hong Kong start control is not configured in this build.')
        url = self.control['url'].rstrip('/') + '/' + route.lstrip('/')
        headers = {'Authorization': 'Bearer ' + self.control['token']}
        payload = {'clientId': self.client_id}
        response = requests.request(method, url, headers=headers,
                                    json=payload if method != 'GET' else None,
                                    params={'clientId': self.client_id} if method == 'GET' else None,
                                    timeout=timeout, verify=certifi.where())
        if response.status_code >= 400:
            raise RuntimeError('Hong Kong connection service returned an error.')
        return response.json()

    def _start_remote(self):
        self._set_status('Starting Hong Kong...')
        result = self._request_control('connect')
        self.remote_lease = True
        deadline = time.monotonic() + 240
        while result.get('state') != 'running':
            if self.cancel_event.is_set():
                raise InterruptedError('Connection cancelled.')
            if time.monotonic() >= deadline:
                raise RuntimeError('Hong Kong is taking too long to start. Try connecting again shortly.')
            time.sleep(5)
            result = self._request_control('status', 'GET')

    def _new_http_session(self):
        session = requests.Session()
        session.trust_env = False
        session.verify = certifi.where()
        session.mount('https://', HTTPAdapter(max_retries=0))
        session.proxies = {
            'http': f'http://127.0.0.1:{self.proxy_port}',
            'https': f'http://127.0.0.1:{self.proxy_port}',
        }
        return session

    def _connect_worker(self):
        try:
            name = self.pending_profile
            if name == 'Hong Kong':
                self._start_remote()
            if self.cancel_event.is_set():
                raise InterruptedError('Connection cancelled.')
            self.connection = parse_vless(self.profiles[name])
            self.proxy_port = available_proxy_port()
            config = build_xray_config(self.connection, self.proxy_port)
            CONFIG_FILE.write_text(json.dumps(config, indent=2) + '\n', encoding='utf-8')
            xray = resource_path('xray.exe')
            check = subprocess.run([str(xray), 'run', '-test', '-config', str(CONFIG_FILE)],
                                   capture_output=True, text=True, timeout=20,
                                   creationflags=subprocess.CREATE_NO_WINDOW)
            if check.returncode:
                raise RuntimeError((check.stderr or check.stdout or 'Xray rejected the connection profile.').strip())
            self.process = subprocess.Popen([str(xray), 'run', '-config', str(CONFIG_FILE)],
                                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                            stderr=subprocess.DEVNULL,
                                            creationflags=subprocess.CREATE_NO_WINDOW)
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                if self.cancel_event.is_set():
                    raise InterruptedError('Connection cancelled.')
                if self.process.poll() is not None:
                    raise RuntimeError('Xray stopped before the local connection was ready.')
                try:
                    with socket.create_connection(('127.0.0.1', self.proxy_port), timeout=1):
                        break
                except OSError:
                    time.sleep(0.5)
            else:
                raise RuntimeError('Xray did not start its local proxy.')
            self._set_status('Checking connection...')
            session = self._new_http_session()
            try:
                response = session.get('https://api.ipify.org', timeout=20)
                response.raise_for_status()
                public_ip = response.text.strip()
                if not public_ip or len(public_ip) > 64:
                    raise RuntimeError('The tunnel did not return a public IP address.')
            finally:
                session.close()
            if self.cancel_event.is_set():
                raise InterruptedError('Connection cancelled.')
            self._enable_system_proxy()
            self.queue.put(('connected', public_ip))
            self.queue.put(('button_state', 'normal'))
            if self.remote_lease:
                threading.Thread(target=self._heartbeat_loop, daemon=True).start()
        except InterruptedError:
            self._cleanup_local()
            self.queue.put(('disconnected', None))
            self.queue.put(('button_state', 'normal'))
        except Exception as error:
            self._cleanup_local()
            self.queue.put(('failed', str(error)))
            self.queue.put(('button_state', 'normal'))

    def _enable_system_proxy(self):
        previous = {name: registry_read(name) for name in ('ProxyEnable', 'ProxyServer', 'ProxyOverride', 'AutoConfigURL')}
        proxy = f'http=127.0.0.1:{self.proxy_port};https=127.0.0.1:{self.proxy_port}'
        state = {'previous': previous, 'activeProxy': proxy, 'proxyPort': self.proxy_port}
        STATE_FILE.write_text(json.dumps({'clientId': self.client_id, 'proxy': state}, indent=2) + '\n', encoding='utf-8')
        try:
            registry_write('ProxyServer', proxy, winreg.REG_SZ)
            registry_write('ProxyOverride', '<local>;localhost;127.*', winreg.REG_SZ)
            registry_write('ProxyEnable', 1, winreg.REG_DWORD)
            refresh_windows_proxy()
        except Exception:
            self._restore_proxy_state(state, force=True)
            raise

    def _restore_proxy_state(self, state, force=False):
        current = registry_read('ProxyServer')
        enabled = registry_read('ProxyEnable')
        is_ours = (current and current[0] == state.get('activeProxy') and
                   enabled and enabled[0] == 1)
        if not force and not is_ours:
            return False
        for name, value in state['previous'].items():
            registry_write(name, value[0], value[1]) if value else registry_write(name, None, winreg.REG_SZ)
        refresh_windows_proxy()
        return True

    def _recover_proxy_if_needed(self):
        try:
            state = json.loads(STATE_FILE.read_text(encoding='utf-8')).get('proxy')
            if state and self._restore_proxy_state(state):
                STATE_FILE.write_text(json.dumps({'clientId': self.client_id}, indent=2) + '\n', encoding='utf-8')
        except (OSError, ValueError, KeyError):
            pass

    def _heartbeat_loop(self):
        while not self.heartbeat_stop.wait(45):
            if not self.remote_lease:
                return
            try:
                self._request_control('heartbeat')
            except Exception:
                self.queue.put(('status', 'Connected; server lease check failed'))

    def _cleanup_local(self):
        self.heartbeat_stop.set()
        try:
            state = json.loads(STATE_FILE.read_text(encoding='utf-8')).get('proxy')
            if state:
                self._restore_proxy_state(state)
        except (OSError, ValueError, KeyError):
            pass
        process = self.process
        self.process = None
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=4)
            except subprocess.TimeoutExpired:
                process.kill()
        if self.remote_lease:
            self.remote_lease = False
            try:
                self._request_control('disconnect')
            except Exception:
                pass
        STATE_FILE.write_text(json.dumps({'clientId': self.client_id}, indent=2) + '\n', encoding='utf-8')

    def _disconnect_worker(self):
        self._cleanup_local()
        self.queue.put(('disconnected', None))
        self.queue.put(('button_state', 'normal'))

    def email_support(self):
        webbrowser.open('mailto:' + SUPPORT_EMAIL + '?subject=Dong%20VPN%20connection%20help')

    def close(self):
        self.cancel_event.set()
        self._cleanup_local()
        self.root.destroy()


def main():
    try:
        root = Tk()
        DongVPN(root)
        root.mainloop()
    except Exception as error:
        messagebox.showerror(APP_TITLE, str(error))


if __name__ == '__main__':
    main()
