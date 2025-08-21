import sys
sys.path.insert(0, '.')

def test_txt2img_mock(tmp_path):
    # Call function directly; it handles absence of torch/diffusers by mock
    import src.diffusion_worker as dw
    paths = dw.txt2img('a prompt', tmp_path)
    assert len(paths) >= 1
    assert tmp_path.exists()
