#include <cuda_runtime.h>
#include <cuda_profiler_api.h>
#include <helper_cuda.h>
#include <algorithm>
#include <iterator>

#include "renderer.h"
#include "voxel_model.h"
#include "device_launch_parameters.h"
#include "pdf.h"
#include "material.h"

void err(cudaError_t err, char *msg)
{
	if (err != cudaSuccess)
	{
		fprintf(stderr, "Failed to %s (error code %s)!\n", msg, cudaGetErrorString(err));
		exit(EXIT_FAILURE);
	}
}

struct pixel_compare {
	const pixel* pixels;
	const uint ns;
	pixel_compare(const pixel* _pixels, uint _ns): pixels(_pixels), ns(_ns) {}

	bool operator() (int p0, int p1) {
		return pixels[p0].done < pixels[p1].done;
	}
};


void renderer::prepare_kernel() {
	const unsigned int num_pixels = nx*ny;
	const uint unit_numpixels = num_pixels / num_units; //TODO make sure we don't miss any rays because of precision loss

	remaining_pixels = num_pixels;
	next_pixel = 0;
	total_rays = 0;

	// allocate device memory for input
    d_heightmap = NULL;
	err(cudaMalloc((void **)&d_heightmap, model->size.x*model->size.z*sizeof(unsigned char)), "allocate device d_scene");

	// Copy the host input in host memory to the device input in device memory
	err(cudaMemcpy(d_heightmap, model->heightmap,model->size.x*model->size.z*sizeof(unsigned char), cudaMemcpyHostToDevice), "copy scene from host to device");

	wunits = new work_unit*[num_units];
	uint cur_idx = 0;
	for (uint unit = 0; unit < num_units; unit++) {
		uint next_idx = cur_idx + unit_numpixels;
		work_unit *wu = new work_unit(cur_idx, next_idx);
		const uint unit_len = wu->length();

		wu->pixel_idx = new int[unit_len];
		wu->samples = new sample[unit_len];

		wu->pixels = new pixel[unit_len];
		for (uint i = 0; i < unit_len; i++)
			wu->pixels[i].samples = 1;

		wu->h_colors = new float3[unit_len];
		for (uint i = 0; i < unit_len; i++)
			wu->h_colors[i] = make_float3(0);

		err(cudaMallocHost(&wu->h_rays, unit_len * sizeof(ray)), "allocate h_rays");
		err(cudaMalloc((void **)&(wu->d_rays), unit_len * sizeof(ray)), "allocate device d_rays");
		err(cudaMalloc((void **)&(wu->d_hits), unit_len * sizeof(cu_hit)), "allocate device d_hits");
		err(cudaMallocHost(&(wu->h_clrs), unit_len * sizeof(clr_rec)), "allocate h_clrs");
		err(cudaMalloc((void **)&(wu->d_clrs), unit_len * sizeof(clr_rec)), "allocate device d_clrs");
		err(cudaStreamCreate(&wu->stream), "cuda stream create");

		wunits[unit] = wu;
		cur_idx = next_idx;
	}

	generate_rays();
}

void renderer::update_camera()
{
	const unsigned int num_pixels = numpixels();

	for (uint unit = 0; unit < num_units; unit++) {
		work_unit* wu = wunits[unit];
		wu->done = false;
		for (uint i = 0; i < wu->length(); i++) {
			wu->pixels[i].samples = 1;
			wu->pixels[i].done = 0;
			wu->h_colors[i] = make_float3(0, 0, 0);
		}
	}

	generate_rays();
	num_runs = 0;
}

void renderer::generate_rays() {
	uint ray_idx = 0;
	for (int j = ny - 1; j >= 0; j--)
		for (int i = 0; i < nx; ++i, ++ray_idx) {
			// for initial generation ray_idx == pixelId
			const uint unit_idx = get_unitIdx(ray_idx);
			generate_ray(wunits[unit_idx], ray_idx, i, j);
		}
}

inline void renderer::generate_ray(work_unit* wu, const uint sampleId, int x, int y) {
	// even though we can compute pixelId from (x,y), we still need the sampleId as its not necessarely the same (as more than a single sample point to the same pixel)
	const float u = float(x + drand48()) / float(nx);
	const float v = float(y + drand48()) / float(ny);
	const uint local_ray_idx = sampleId - wu->start_idx;
	cam->get_ray(u, v,wu->h_rays[local_ray_idx]);
	wu->samples[local_ray_idx] = sample(get_pixelId(x, y));
}

__global__ void hit_scene(const ray* rays, const uint num_rays, const unsigned char* heightmap, const uint3 model_size, float t_min, float t_max, cu_hit* hits)
{
	int i = blockDim.x * blockIdx.x + threadIdx.x;
	if (i >= num_rays) return;

	const ray *r = &(rays[i]);
	const voxelModel model(heightmap, model_size);
	cu_hit hit;
	if (!model.hit(*r, t_min, t_max, hit)) {
		hits[i].hit_face = NO_HIT;
		return;
	}

	hits[i].hit_face = hit.hit_face;
	hits[i].hit_t = hit.hit_t;
}

__global__ void simple_color(const ray* rays, const uint num_rays, const cu_hit* hits, clr_rec* clrs, const uint seed, const float3 albedo, const int max_depth) {
	const int ray_idx = blockDim.x * blockIdx.x + threadIdx.x;
	if (ray_idx >= num_rays) return;

	const ray& r = rays[ray_idx];
	const cu_hit hit(hits[ray_idx]);
	clr_rec& crec = clrs[ray_idx];

	if (hit.hit_face == NO_HIT) {
		// no intersection with spheres, return sky color
		float3 unit_direction = normalize(r.direction);
		float t = 0.5*(unit_direction.y + 1.0);
		crec.color = 1.0* ((1 - t)*make_float3(1.0, 1.0, 1.0) + t*make_float3(0.5, 0.7, 1.0));
		crec.done = true;
		return;
	}

	const float3 hit_n = make_float3(
		-1 * (hit.hit_face == X)*signum(r.direction.x),
		-1 * (hit.hit_face == Y)*signum(r.direction.y),
		-1 * (hit.hit_face == Z)*signum(r.direction.z)
	);

	hit_record rec(r.point_at_parameter(hit.hit_t), hit_n);
	curandStatePhilox4_32_10_t localState;
	curand_init(0, seed*blockDim.x + threadIdx.x, 0, &localState);
	lambertian mat(albedo);

	scatter_record srec;
	mat.scatter(rec, srec);
	srec.scattered = ray(rec.hit_p, srec.pdf_ptr->generate(&localState));
	const float pdf_val = srec.pdf_ptr->value(srec.scattered.direction);
	if (pdf_val > 0) {
		const float scattering_pdf = mat.scattering_pdf(rec, srec.scattered);
		srec.attenuation *= scattering_pdf / pdf_val;

		crec.origin = srec.scattered.origin;
		crec.direction = srec.scattered.direction;
		crec.color = srec.attenuation;
		crec.done = false;

		// following code can be useful to debug rendering issues
		//const uint max_dir = max_id(srec.scattered.direction);
		//crec.color = (make_float3(
		//	(max_dir == 0)*signum(srec.scattered.direction.x),
		//	(max_dir == 1)*signum(srec.scattered.direction.y),
		//	(max_dir == 2)*signum(srec.scattered.direction.z)
		//) + 1) / 2;
		//crec.color = (normalize(hit_n) + 1) / 2;
		//crec.done = true;
	} else {
		crec.color = make_float3(0, 0, 0);
		crec.done = true;
	}
	delete srec.pdf_ptr;
}

void renderer::copy_rays_to_gpu(const work_unit* wu) {
	err(cudaMemcpyAsync(wu->d_rays, wu->h_rays, wu->length() * sizeof(ray), cudaMemcpyHostToDevice, wu->stream), "copy rays from host to device");
}

void renderer::copy_colors_from_gpu(const work_unit* wu) {
	err(cudaMemcpyAsync(wu->h_clrs, wu->d_clrs, wu->length() * sizeof(clr_rec), cudaMemcpyDeviceToHost, wu->stream), "copy results from device to host");
}

void renderer::start_kernel(const work_unit* wu) {
	int threadsPerBlock = 128;
	int blocksPerGrid = (wu->length() + threadsPerBlock - 1) / threadsPerBlock;
	hit_scene <<<blocksPerGrid, threadsPerBlock, 0, wu->stream >>>(wu->d_rays, wu->length(), d_heightmap, model->size, 0.1f, FLT_MAX, wu->d_hits);
	simple_color <<<blocksPerGrid, threadsPerBlock, 0, wu->stream >>>(wu->d_rays, wu->length(), wu->d_hits, wu->d_clrs, num_runs++, model_albedo, max_depth);
}

void renderer::render_work_unit(uint unit_idx) {
	work_unit* wu = wunits[unit_idx];
	while (!wu->done) {
		wu->num_iter++;
		clock_t start = clock();
		copy_rays_to_gpu(wu);
		start_kernel(wu);
		copy_colors_from_gpu(wu);
		cudaStreamQuery(wu->stream); // flush stream to start the kernel 
		cudaStreamSynchronize(wu->stream);
		clock_t end = clock();
		wu->gpu_time += end - start;
		compact_rays(wu);
		wu->cpu_time += clock() - end;
	}
}

void renderer::compact_rays(work_unit* wu) {
	uint done_samples = 0;
	bool not_done = false;
	for (uint i = 0; i < wu->length(); ++i) {
		const clr_rec& crec = wu->h_clrs[i];
		sample& s = wu->samples[i];
		const uint local_pixelId = s.pixelId - wu->start_idx;
		s.done = crec.done || s.depth == max_depth;
		if (s.done) {
			if (crec.done) wu->h_colors[local_pixelId] += s.not_absorbed*crec.color;
			++(wu->pixels[local_pixelId].done);
			++done_samples;
		} else {
			s.not_absorbed *= crec.color;
			wu->h_rays[i].origin = crec.origin;
			wu->h_rays[i].direction = crec.direction;
			++s.depth;
		}
		not_done = not_done || (wu->pixels[local_pixelId].done < ns);
	}

	if (done_samples > 0 && not_done) {
		// sort uint ray [wu->start_idx, wu->end_idx[
		for (uint i = 0; i < wu->length(); ++i) wu->pixel_idx[i] = i;
		std::sort(wu->pixel_idx, wu->pixel_idx + wu->length(), pixel_compare(wu->pixels, ns));
		uint sampled = 0;
		for (uint i = 0; i < wu->length(); ++i) {
			const uint sId = wu->start_idx + i;
			sample& s = wu->samples[i];
			if (s.done) {
				// generate new ray
				const uint local_pixelId = wu->pixel_idx[sampled++];
				const uint pixelId = wu->start_idx + local_pixelId;
				wu->pixels[local_pixelId].samples++;
				// then, generate a new sample
				const unsigned int x = pixelId % nx;
				const unsigned int y = ny - 1 - (pixelId / nx);
				generate_ray(wu, sId, x, y);
			}
		}
	}

	wu->done = !not_done;
}

void renderer::destroy() {
	// Free device global memory
	err(cudaFree(d_heightmap), "free device d_heightmap");

	for (uint unit = 0; unit < num_units; unit++) {
		work_unit *wu = wunits[unit];
		err(cudaFree(wu->d_rays), "free device d_rays");
		err(cudaFree(wu->d_hits), "free device d_hits");
		err(cudaFree(wu->d_clrs), "free device d_clrs");

		err(cudaStreamDestroy(wu->stream), "destroy cuda stream");

		cudaFreeHost(wu->h_clrs);
		cudaFreeHost(wu->h_rays);

		delete[] wu->pixel_idx;
		delete[] wu->samples;
		delete[] wu->pixels;
		delete[] wu->h_colors;
	}

	// Free host memory
	delete[] wunits;
}