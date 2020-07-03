#version 410 core

#define EARTH_RADIUS 6378100.0
#define EARTH_CENTER vec3(0.0, -1.0 * EARTH_RADIUS, 0.0)

#define SAMPLE_STEP_COUNT 64
#define SUN_STEP_COUNT 4

#define MAXIMUM_SAMPLE_STEP_SIZE 200.0

#define CLOUD_LAYER_COUNT 3
#define CLOUD_TYPE_COUNT 5

#define PI 3.141592653589793

flat in mat4 inverse_modelview_matrix;
flat in mat4 inverse_projection_matrix;

in vec3 ray_start_position;
in vec3 ray_end_position;

in vec2 depth_texture_position;

uniform sampler2D depth_texture;

uniform sampler2D cloud_map_texture;

uniform sampler3D base_noise_texture;
uniform sampler3D detail_noise_texture;

uniform sampler2D blue_noise_texture;

uniform float cloud_map_scale;

uniform float base_noise_scale;
uniform float detail_noise_scale;

uniform float blue_noise_scale;

uniform vec3 camera_position;

uniform float[CLOUD_LAYER_COUNT] cloud_bases;
uniform float[CLOUD_TYPE_COUNT] cloud_heights;

uniform int[CLOUD_LAYER_COUNT] cloud_types;
uniform float[CLOUD_TYPE_COUNT] cloud_coverages;

uniform vec3[CLOUD_TYPE_COUNT] base_noise_ratios;
uniform vec3[CLOUD_TYPE_COUNT] detail_noise_ratios;

uniform float[CLOUD_TYPE_COUNT] cloud_densities;

uniform float fade_start_distance;
uniform float fade_end_distance;

uniform vec3 sun_direction;

uniform vec3 sun_tint;
uniform float sun_gain;

uniform vec3 atmosphere_tint;
uniform float atmospheric_blending;

uniform float in_scattering;

uniform float forward_mie_scattering;
uniform float backward_mie_scattering;

uniform float local_time;

layout(location = 0) out vec4 fragment_color;

float map(in float input_value, in float input_start, in float input_end, in float output_start, in float output_end)
{
	float slope = (output_end - output_start) / (input_end - input_start);

	return clamp(output_start + (slope * (input_value - input_start)), min(output_start, output_end), max(output_start, output_end));
}

float henyey_greenstein(in float dot_angle, in float scattering_value)
{
	float squared_scattering_value = pow(scattering_value, 2.0);

	return (1.0 - squared_scattering_value) / (4.0 * PI * pow(squared_scattering_value - (2.0 * scattering_value * dot_angle) + 1.0, 1.5));
}

float get_height_ratio(in vec3 ray_position, in int layer_index)
{
	return map(length(ray_position - EARTH_CENTER) - EARTH_RADIUS, cloud_bases[layer_index], cloud_bases[layer_index] + cloud_heights[cloud_types[layer_index] - 1], 0.0, 1.0);
}

float sample_clouds(in vec3 ray_position, in int layer_index)
{
	vec4 base_noise_sample = texture(base_noise_texture, ray_position * base_noise_scale);
	float base_noise = map(base_noise_sample.x, dot(base_noise_sample.yzw, base_noise_ratios[cloud_types[layer_index] - 1]), 1.0, 0.0, 1.0);

	float height_ratio = get_height_ratio(ray_position, layer_index);
	float height_multiplier = map(height_ratio, 0.0, 0.025, 0.0, 1.0) * map(height_ratio, 0.25, 1.0, 1.0, 0.0);

	float base_erosion = map(base_noise * height_multiplier, 1.0 - max(texture(cloud_map_texture, ray_position.xz * cloud_map_scale).x, cloud_coverages[cloud_types[layer_index] - 1]), 1.0, 0.0, 1.0);

	if (base_erosion > 0.01)
	{
		vec3 detail_noise_sample = texture(detail_noise_texture, ray_position * detail_noise_scale).xyz;
		float detail_noise = dot(detail_noise_sample, detail_noise_ratios[cloud_types[layer_index] - 1]);

		return map(base_erosion, detail_noise, 1.0, 0.0, 1.0);
	}
	else return base_erosion;
}

float ray_sphere_intersection(in vec3 ray_start_position, in vec3 ray_direction, in float sphere_height)
{
	vec3 ray_earth_vector = ray_start_position - EARTH_CENTER;

	float coefficient_1 = 2.0 * dot(ray_direction, ray_earth_vector);
	float coefficient_2 = dot(ray_earth_vector, ray_earth_vector) - pow(EARTH_RADIUS + sphere_height, 2.0);

	float discriminant = pow(coefficient_1, 2.0) - (4.0 * coefficient_2);

	if (discriminant < 0.0) return 0.0;
	else
	{
		float lower_solution = ((-1.0 * coefficient_1) - sqrt(discriminant)) / 2.0;
		float higher_solution = ((-1.0 * coefficient_1) + sqrt(discriminant)) / 2.0;

		if (lower_solution < 0.0) return max(0.0, higher_solution);
		else return lower_solution;
	}
}

vec4 ray_march(in int layer_index, in vec4 input_color)
{
	vec4 output_color = input_color;
	
	if (cloud_types[layer_index] != 0)
	{
		vec3 sample_ray_direction = normalize(ray_end_position - ray_start_position);

		float inner_sphere_distance = ray_sphere_intersection(ray_start_position, sample_ray_direction, cloud_bases[layer_index]);
		float outer_sphere_distance = ray_sphere_intersection(ray_start_position, sample_ray_direction, cloud_bases[layer_index] + cloud_heights[cloud_types[layer_index] - 1]);

		float near_sphere_distance = min(inner_sphere_distance, outer_sphere_distance);
		float far_sphere_distance = max(inner_sphere_distance, outer_sphere_distance);

		vec4 world_vector = inverse_projection_matrix * vec4((depth_texture_position * 2.0) - 1.0, map(texture(depth_texture, depth_texture_position).x, 0.0, 1.0, -1.0, 1.0), 1.0);
		world_vector /= world_vector.w;

		vec3 world_position = vec3(inverse_modelview_matrix * world_vector);
		float world_distance = length(world_position - ray_start_position);

		float ray_start_distance = 0.0;
		float ray_march_distance = 0.0;

		float height_ratio = get_height_ratio(ray_start_position, layer_index);

		if ((height_ratio > 0.0) && (height_ratio < 1.0))
		{
			if (near_sphere_distance == 0.0) ray_march_distance = far_sphere_distance;
			else ray_march_distance = near_sphere_distance;
		}
		else
		{
			ray_start_distance = near_sphere_distance;
			ray_march_distance = far_sphere_distance - near_sphere_distance;
		}

		ray_start_distance = min(ray_start_distance, world_distance);
		ray_march_distance = min(ray_march_distance, world_distance - ray_start_distance);

		if (ray_march_distance != 0.0)
		{
			vec3 sample_ray_position = ray_start_position + (sample_ray_direction * ray_start_distance);
			float sample_ray_distance = 0.0;

			float sample_step_size = min(ray_march_distance / SAMPLE_STEP_COUNT, MAXIMUM_SAMPLE_STEP_SIZE);
			float sun_step_size = cloud_heights[cloud_types[layer_index] - 1] / SUN_STEP_COUNT;

			float sun_dot_angle = dot(sample_ray_direction, -1.0 * sun_direction);
			float mie_scattering_gain = clamp(mix(henyey_greenstein(sun_dot_angle, forward_mie_scattering), henyey_greenstein(sun_dot_angle, -1.0 * backward_mie_scattering), 0.5), 0.75, 2.5);

			while (sample_ray_distance <= ray_march_distance)
			{
				float cloud_sample_1 = sample_clouds(sample_ray_position, layer_index);

				if (cloud_sample_1 != 0.0)
				{
					vec3 sun_ray_position = sample_ray_position;

					float blocking_density = 0.0;

					for (int sun_step = 0; sun_step < SUN_STEP_COUNT; sun_step++)
					{
						blocking_density += sample_clouds(sun_ray_position, layer_index) * cloud_densities[cloud_types[layer_index] - 1];

						sun_ray_position += sun_direction * sun_step_size;
					}

					float sample_attenuation = clamp(exp(-1.0 * blocking_density) * (1.0 - exp(-2.0 * in_scattering * blocking_density)), 0.25, 1.0);
					vec3 sample_color = clamp(mix(sun_tint, atmosphere_tint, atmospheric_blending) * sun_gain * mie_scattering_gain * sample_attenuation, 0.0, 1.0);

					float alpha_multiplier = 1.0 - smoothstep(0.0, 1.0, map(length(sample_ray_position - camera_position), fade_start_distance, fade_end_distance, 0.0, 1.0));
					if (alpha_multiplier < 0.01) break;

					float sample_alpha = cloud_sample_1 * alpha_multiplier;

					output_color.xyz += sample_color * sample_alpha * output_color.w;
					output_color.w *= 1.0 - sample_alpha;

					if (output_color.w < 0.01) break;
				}

				float current_step_size = sample_step_size;

				sample_ray_position += sample_ray_direction * current_step_size;
				sample_ray_distance += current_step_size;
			}
		}
	}

	return output_color;
}

void main()
{
	vec4 output_color = vec4(0.0, 0.0, 0.0, 1.0);

	int first_higher_layer = 0;
	while ((first_higher_layer < CLOUD_LAYER_COUNT) && ((cloud_bases[first_higher_layer] + cloud_heights[cloud_types[first_higher_layer] - 1]) < camera_position.y)) first_higher_layer++;

	for (int layer_index = first_higher_layer; layer_index < CLOUD_LAYER_COUNT; layer_index++) output_color = ray_march(layer_index, output_color);
	for (int layer_index = first_higher_layer - 1; layer_index >= 0; layer_index--) output_color = ray_march(layer_index, output_color);

	fragment_color = vec4(output_color.xyz, 1.0 - output_color.w);
}
