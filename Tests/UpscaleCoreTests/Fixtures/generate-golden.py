import json, os, socket, subprocess, sys, time

repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
shader_dir = os.path.join(repo_root, "Sources", "UpscaleCore", "Resources", "Shaders")
files = sys.argv[1].split(",")
src = sys.argv[2]
out_name = sys.argv[3]
w, h = sys.argv[4], sys.argv[5]

shaders = ":".join(os.path.join(shader_dir, f + ".glsl") for f in files)
sock_path = os.path.abspath("mpvsock")
if os.path.exists(sock_path):
    os.unlink(sock_path)

cmd = [
    "mpv", "--no-config", "--vo=gpu", "--gpu-api=vulkan",
    "--glsl-shaders=" + shaders,
    "--geometry=%sx%s" % (w, h), "--autofit=%sx%s" % (w, h),
    "--no-keepaspect-window", "--no-border", "--no-osc", "--no-osd-bar",
    "--dither=no", "--fbo-format=rgba16f", "--scale=bilinear",
    "--linear-downscaling=no", "--sigmoid-upscaling=no", "--correct-downscaling=no",
    "--screenshot-format=png", "--screenshot-directory=" + os.getcwd(),
    "--screenshot-template=" + out_name,
    "--image-display-duration=inf", "--keep-open=yes",
    "--input-ipc-server=" + sock_path,
    src,
]
proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

deadline = time.time() + 25
sock = None
while time.time() < deadline:
    if os.path.exists(sock_path):
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(sock_path)
            break
        except OSError:
            sock = None
    if proc.poll() is not None:
        print("mpv exited early:\n" + proc.stdout.read().decode())
        sys.exit(1)
    time.sleep(0.2)

if sock is None:
    proc.kill()
    print("no ipc socket; mpv output:\n" + proc.stdout.read().decode())
    sys.exit(1)

time.sleep(2.0)  # let the first frame render with shaders applied
sock.sendall(json.dumps({"command": ["screenshot", "window"]}).encode() + b"\n")
time.sleep(2.0)
sock.sendall(json.dumps({"command": ["quit"]}).encode() + b"\n")
try:
    proc.wait(timeout=10)
except subprocess.TimeoutExpired:
    proc.kill()
print(proc.stdout.read().decode()[-3000:])
