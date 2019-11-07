classdef RRT_star_HLP < RRT_HLP
% Class: RRT_star_HLP < RRT_HLP
%
% This implements RRT* as a high-level planner for the simulator framework.
% For now, it only works for 2D worlds/obstacles.
%
% The algorithm follows this paper:
% http://roboticsproceedings.org/rss06/p34.pdf
%
% Authors: Shreyas Kousik and Bohao Zhang
% Created: Nov 2019
% Updated: 6 Nov 2019
    
    properties
        costs
        rewire_distance = 1 ; % nodes within this distance of a new node
                              % candidates for rewiring
        best_path_cost ;
    end
    
    methods
        %% constructor
        function HLP = RRT_star_HLP(varargin)
            goal_as_new_node_rate = 0.1 ; % different from default RRT
            HLP@RRT_HLP('goal_as_new_node_rate',goal_as_new_node_rate,...
                varargin{:}) ;
        end
        
        %% tree growth
        function initialize_tree(HLP,agent_info)
            initialize_tree@RRT_HLP(HLP,agent_info)
            
            % initialize cost
            switch HLP.grow_tree_mode
                case 'new'
                    HLP.costs = 0 ;
                case 'seed'
                    HLP.nodes = HLP.best_path_cost ;
                case 'keep'
                    HLP.vdisp('Keeping previous cost!',10)
                otherwise
                    error('Please pick a valid tree growth mode!')
            end
            
            if isempty(HLP.costs)
                HLP.costs = 0 ;
            end
        end
        
        %% extend
        function extend_success_flag = extend(HLP,agent_info,world_info,rand_node)
            % get new node
            [nearest_node,nearest_node_distance,nearest_node_index] = HLP.find_nearest_node(rand_node) ;
            new_node = HLP.steer(rand_node,nearest_node,nearest_node_distance) ;
            
            % make sure the new node and nearest node are not the same
            new_node_not_duplicate = ~(vecnorm(new_node - nearest_node) == 0) ;
            
            % check that we can connect to the nearest node
            if new_node_not_duplicate
                nearest_node_connect_flag = HLP.edge_feasibility_check(new_node,nearest_node,world_info) ;
            else
                nearest_node_connect_flag = false ;
            end
            
            % preallocate candidate parent indices and costs
            candidate_indices = [] ;
            candidate_costs = [] ;
            
            % get all nodes within rewire distance of new node (note that
            % the nearest node might be one of these)
            near_distances = vecnorm(HLP.nodes - repmat(new_node,1,HLP.N_nodes)) ; % length is N_nodes
            near_log = near_distances <= HLP.rewire_distance ; % length is N_nodes
            node_indices = 1:HLP.N_nodes ; % length is N_nodes
            near_indices = node_indices(near_log) ; % length is N_near (see below)
            
            % collision check with any nodes within the rewire distance
            if ~isempty(near_indices)
                N_near = length(near_indices) ;
                near_nodes_edge_feasible_log = false(1,N_near) ; % pessimism
                
                for idx = 1:N_near
                    near_idx = near_indices(idx) ;
                    near_node = HLP.nodes(:,near_idx) ;
                    near_nodes_edge_feasible_log(idx) = HLP.edge_feasibility_check(new_node,near_node,world_info) ;
                end
                
                % get indices of feasible nearest nodes as candidate parents
                candidate_indices = near_indices(near_nodes_edge_feasible_log) ;
                candidate_costs = HLP.costs(candidate_indices) ;
            end
            
            % add nearest node to the list if it is feasible
            if nearest_node_connect_flag
                candidate_indices = [candidate_indices, nearest_node_index] ;
                candidate_costs = [candidate_costs, HLP.costs(nearest_node_index)] ;
            end
            
            if ~isempty(candidate_indices)
                % if there are candidate indices, connect to cheapest
                [~,cheapest_parent_index] = min(candidate_costs) ;
                parent_index = candidate_indices(cheapest_parent_index) ;
                
                % get the cost of the new node
                candidate_distances = near_distances(candidate_indices) ;
                parent_distance = candidate_distances(cheapest_parent_index) ;
                new_cost = candidate_costs(cheapest_parent_index) + parent_distance ;
                
                % extend successful!
                extend_success_flag = true ;
            else
                % otherwise, we cannot extend to the new node
                extend_success_flag = false ;
            end
            
            % if there is a parent index...
            if extend_success_flag
                % add the node to the tree
                HLP.add_node_to_tree(new_node,parent_index) ;
                
                % update the cost
                HLP.costs = [HLP.costs, new_cost] ;
                
                % REWIRE THE TREE
                % first, get the indices and distances for all the nearby
                % nodes that are NOT the new parent node
                candidate_indices(cheapest_parent_index) = [] ;
                candidate_distances(cheapest_parent_index) = [] ;
                candidate_costs(cheapest_parent_index) = [] ;
                
                % get the new costs of connecting the candidate indices to
                % the new node
                new_costs = candidate_distances + new_cost ;
                
                % compare the new costs to the original costs
                rewire_log = new_costs < candidate_costs ;
                
                % get the node indices to rewire
                rewire_indices = candidate_indices(rewire_log) ;
                
                % rewire the tree
                HLP.nodes_parent(rewire_indices) = HLP.N_nodes ;
            end
        end
        
        %% add node        
%         function [near_distances,near_indices] = find_nearest_nodes(HLP)
%             % get indices of all nodes that are candidates for rewiring
%             indices = 1:(HLP.N_nodes-1) ; % ignore the latest node
%             indices(indices == HLP.nodes_parent(end)) = [] ; % ignore the latest parent
%             
%             % find all nodes within rewire distance of new node
%             near_distances = vecnorm(HLP.nodes(:,indices) - repmat(HLP.nodes(:,end),1,HLP.N_nodes - 2)) ;
%             near_distances_log = near_distances <= HLP.rewire_distance ;
%             near_indices = indices(near_distances_log) ;
%             near_distances = near_distances(near_distances_log) ;
%         end
%         
%         function rewire(HLP,world_info)
%             % get the newest node
%             new_node = HLP.nodes(:,end) ;
%             
%             % get nearby node indices
%             [~,~,near_indices] = HLP.find_nearest_nodes(new_node) ;
%             
%             % for each near node, check if its edge is feasible and its
%             % cost is lower by attaching to the new node
%             obstacles = world_info.obstacles ;
%             for idx = near_indices
%                 near_node = HLP.nodes(:,idx) ;
%                 new_edge_feasible = HLP.edge_feasibility_check(new_node,near_node,obstacles) ;
%                 
%                 % if HLP.plot_while_growing_tree_flag
%                 %     plot_path(near_node,'r.')
%                 %     drawnow()
%                 % end
%                 
%                 if new_edge_feasible
%                     new_cost = HLP.cost(end) + vecnorm(new_node - near_node) ;
%                     if new_cost < HLP.cost(idx)
%                         HLP.nodes_parent(idx) = HLP.N_nodes ;
%                         
%                         % if HLP.plot_while_growing_tree_flag
%                         %     plot_path(near_node,'ro')
%                         %     drawnow()
%                         % end
%                     end
%                 end
%             end
%         end
        
    %% path planning
    function exit_flag = find_best_path(HLP)
        exit_flag = find_best_path@RRT_HLP(HLP) ;
        
        % get best path cost
        HLP.best_path_cost = HLP.costs(HLP.best_path_indices) ;
    end
    end
end