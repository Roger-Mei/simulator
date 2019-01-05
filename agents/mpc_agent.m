classdef mpc_agent < agent2D
    
properties
    reference_trajectory
    reference_input
    time_discretization
    default_prediction_horizon
    prediction_horizon
    A_jacobian
    B_jacobian
    input_range
    linearized_xy_range
    linearized_heading_range
    state_cost
    n_decision_variables
    n_decision_variable_states
    n_decision_variable_inputs
    input_cost
    agent_state_time_discretization
end

methods
%% constructoer

function A=mpc_agent(mpc_dynamics,varargin)
    
    A@agent2D(varargin{:})
    
    for idx = 1:2:length(varargin)
        switch varargin{idx}
            case 'time_discretization'
                A.time_discretization = varargin{idx+1} ;
            case 'default_prediction_horizon'
                A.default_prediction_horizon = varargin{idx+1} ;
            case 'input_range'
                A.input_range = varargin{idx+1} ; 
            case 'linearized_xy_range'
                A.linearized_xy_range = varargin{idx+1} ;
            case 'linearized_heading_range'
                A.linearized_heading_range = varargin{idx+1} ;
            case 'state_cost'
                A.state_cost = varargin{idx+1} ;
            case 'input_cost'
                A.input_cost = varargin{idx+1} ;
            case 'agent_state_time_discretization'
                A.agent_state_time_discretization = varargin{idx+1} ;
        end
    end
    
    
    %setup
    if A.agent_state_time_discretization>A.time_discretization
        A.agent_state_time_discretization=A.time_discretization;
    end

    [A.A_jacobian,A.B_jacobian] = generate_jacobians_from_mpc_dynamics_function(A,mpc_dynamics);

end

%% function to reset states and reference trajectory
function reset(A,state)
    A.time=0;
    A.state=state;
    A.input_time=0;
    A.input=[NaN;NaN];
    A.reference_trajectory=[];
    A.reference_input=[];
end


%% function to move and do mpc loop
function move(A,T_total,T_input,U_input,Z_desired)
    %if the desired time to move is longer than the reference trajectory,
    %throw an error
    T_input=T_input-T_input(1);
    
    ref_time=0:A.time_discretization:T_input(end);
    if ref_time(end) < T_total
        warning(['Provided input time vector is shorter than the ',...
            'desired motion time! modifying reference trajectory by repeating last state'])
        
        if mod(T_total,A.time_discretization)~=0
            T_input=[T_input,T_total+A.time_discretization-mod(T_total,A.time_discretization)];
        else
            T_input=[T_input,T_total];
        end
        
        U_input=[U_input,U_input(:,end)];
        Z_desired=[Z_desired,Z_desired(:,end)];
    end
    
    %if the reference trajectory is not given at the proper time
    %discretization interporlate
    if any(diff(T_input)~=A.time_discretization)
        
        warning(['reference trajectory not given at correct timestep'])

        ref_time = 0:A.time_discretization:T_input(end);
        U_input = interp1(T_input',U_input',ref_time','previous','extrap')';
        Z_desired = interp1(T_input',Z_desired',ref_time','pchip','extrap')';
        T_input = ref_time;
    end

    %
    T_out_input=unique([0:A.time_discretization:T_total,T_total]);
    
    %applied inputs
    U_out=NaN(A.n_inputs,length(T_out_input));
    
    T_out=unique([T_out_input,0:A.agent_state_time_discretization:T_total,T_total]);
    
    Z_out=NaN(A.n_states,length(T_out));
    
    Z_out(:,1)=A.state(:,end);
     
    for i=1:length(T_out_input)-1
        
        prediction_horizon=min([A.default_prediction_horizon,length(T_out_input)-i]);
        
        set_problem_size(A,prediction_horizon);
        
        L=(T_out>=T_out_input(i))&((T_out<=T_out_input(i+1)));
        
        start_idx=find(L,1);
        
        tvec=T_out(L);
          
        x_initial=Z_out(:,start_idx)-Z_desired(:,i);
        
        x_initial(A.heading_state_index)=rad2heading(x_initial(A.heading_state_index));
        
        [Aeq,beq] = get_equality_constraints(A,x_initial,T_input,Z_desired,U_input,i);
        
        [Aineq,bineq] = get_inequality_constraints(A,T_input,Z_desired,U_input,i);
        
        H = get_cost_matrix(A);
        
        f=zeros(A.n_decision_variables,1);
  
        [x,~,exitflag] = quadprog(H,f,Aineq,bineq,Aeq,beq);
        
        if exitflag<0
            warning('qp infeasible, apply reference input')
            x=zeros(A.n_decision_variables,1);
        end
        %get linearized output
        u_mpc = x(A.n_decision_variable_states+1:A.n_decision_variable_states+A.n_inputs);
        
        U_out(:,i)=u_mpc+U_input(:,i);
        
        %simulate dynamics
        [~,ztemp]=ode45(@(t,z)A.dynamics(t,z,T_out_input(i),U_out(:,i)),tvec,Z_out(:,start_idx));
    
        if length(tvec)==2
            Z_out(:,L)=ztemp([1,end],:)';
        else
            Z_out(:,L)=ztemp';
        end
        
    end
    
    A.state = [A.state(:,1:end-1),Z_out];
    
    A.time = [A.time,A.time(end)+T_out(2:end)];
    
    %remove time points that are almost duplicates due to rounding errors
    tol=min([1e-9,A.agent_state_time_discretization]);
    
    L=diff(A.time)<tol;
    
    A.time(L)=[];
    
    A.state(:,L)=[];
    
    A.input = [A.input(:,1:end-1),U_out];
    
    A.input_time = [A.input_time , A.input_time(end)+T_out_input(2:end)];
    
    A.reference_input = [A.reference_input(:,1:end-1) , interp1(T_input',U_input',T_out_input','previous')'];
    
    A.reference_trajectory = [A.reference_trajectory(:,1:end-1) , interp1(T_input',Z_desired',T_out_input','pchip')'];
    
   
end

%% functions to get constraints for lmpc program        
function [Aeq,beq] = get_equality_constraints(A,x_initial,T,Z,U,reference_index)
%build matrix for A_i*x_i+B_i*u_i-x_{i+1}=0
%in the form Aeq*z=beq
%initial_idx specifies the time index of initial condition from the reference trajectory 
%A and B are function handles above


Aeq = zeros(A.n_decision_variable_states,A.n_decision_variables);
Aeq(1:A.n_states,1:A.n_states) = eye(A.n_states); %initial condition 
beq = zeros(A.n_decision_variable_states,1);
beq(1:A.n_states) = x_initial;

state_idxs = A.n_states + 1:A.n_states:A.n_decision_variable_states;
input_idxs = A.n_decision_variable_states + 1:A.n_inputs:A.n_decision_variables;

for i=1:A.prediction_horizon
    
    ztemp = Z(:,reference_index+i-1);
    
    utemp = U(:,reference_index+i-1);
    
    ttemp = T(:,reference_index+i-1);
    
    %negative identity for i+1
    Aeq(state_idxs(i):state_idxs(i)+A.n_states-1,state_idxs(i):state_idxs(i)+A.n_states-1) = -eye(A.n_states);
    
    %A matrix for i
    Aeq(state_idxs(i):state_idxs(i)+A.n_states-1,state_idxs(i)-A.n_states:state_idxs(i)-1) = A.A_jacobian(ttemp,ztemp,utemp);
    
    %B matrix for i
    Aeq(state_idxs(i):state_idxs(i)+A.n_states-1,input_idxs(i):input_idxs(i)+A.n_inputs-1) = A.B_jacobian(ttemp,ztemp,utemp);
end

end
 
function [Aineq,bineq] = get_inequality_constraints(A,~,~,U,reference_index)   
    Aineq_xy=[];
    Aineq_h=[];
    Aineq_input=[];
    
    bineq_xy=[];
    bineq_h=[];
    bineq_input=[];
    
    %get bounds for linearized xy state
    if ~isempty(A.linearized_xy_range)
        Aineq_xy = [get_state_selector_matrix(A,A.xy_state_indices);-get_state_selector_matrix(A,A.xy_state_indices)];
        bineq_xy = [repmat(A.linearized_xy_range(:,2),[A.prediction_horizon+1,1]);...
            -repmat(A.linearized_xy_range(:,1),[A.prediction_horizon+1,1])];
    end
    
    %get bounds for linearized heading state
    if ~isempty(A.linearized_heading_range)
        Aineq_h = [get_state_selector_matrix(A,A.heading_state_index);-get_state_selector_matrix(A,A.heading_state_index)];
        bineq_h = [repmat(A.linearized_heading_range(2),[A.prediction_horizon+1,1]);...
            -repmat(A.linearized_heading_range(:,1),[A.prediction_horizon+1,1])];
    end
    
    %get bounds for input (range is given for the system model (not
    %linearized)
    if ~isempty(A.input_range)
        
        Aineq_input = [zeros(A.n_decision_variable_inputs,A.n_decision_variable_states),eye(A.n_decision_variable_inputs);...
            zeros(A.n_decision_variable_inputs,A.n_decision_variable_states),-eye(A.n_decision_variable_inputs)];
        
        bineq_input_ub = repmat(A.input_range(:,2),[1,A.prediction_horizon])-U(:,reference_index:reference_index+A.prediction_horizon-1);
        bineq_input_lb = repmat(A.input_range(:,1),[1,A.prediction_horizon])-U(:,reference_index:reference_index+A.prediction_horizon-1);
        
        bineq_input_ub=reshape(bineq_input_ub,[A.n_inputs*A.prediction_horizon,1]);
        bineq_input_lb=reshape(bineq_input_lb,[A.n_inputs*A.prediction_horizon,1]);
        
        bineq_input=[bineq_input_ub;-bineq_input_lb];
    end
    
    Aineq=[Aineq_xy;Aineq_h;Aineq_input];
    
    bineq=[bineq_xy;bineq_h;bineq_input];
   
    
end

%% helper functions
%set sizes for other functions
function set_problem_size(A,prediction_horizon)
    A.n_decision_variable_states=(prediction_horizon+1)*A.n_states;
    A.n_decision_variable_inputs=prediction_horizon*A.n_inputs;
    A.n_decision_variables=A.n_decision_variable_states+A.n_decision_variable_inputs;
    A.prediction_horizon=prediction_horizon;
end

%construct cost matrix
function H = get_cost_matrix(A)
    if isempty(A.state_cost)
        Q = eye(A.n_states);
    else
        Q = A.state_cost;
    end
    
    if isempty(A.input_cost)
        R = eye(A.n_inputs);
    else
        R = A.input_cost;
    end
    
    tmp_state=repmat({Q},A.prediction_horizon+1,1);
    tmp_input=repmat({R},A.prediction_horizon,1);
    tmp=[tmp_state;tmp_input];
       
    H=blkdiag(tmp{:});
end

%generate jacobians for euler constraints
function [A_jac,B_jac] = generate_jacobians_from_mpc_dynamics_function(A,mpc_dynamics)
    syms t real;
    z=sym('z',[A.n_states,1],'real');
    u=sym('u',[A.n_inputs,1],'real');
    
    symbolic_dynamics=mpc_dynamics(t,z,u);
    
    A_jac_cont = jacobian(symbolic_dynamics,z');
    A_jac_discrete = eye(A.n_states)+A.time_discretization*A_jac_cont;
    A_jac = matlabFunction(A_jac_discrete,'Vars',{t,z,u});
    
    B_jac_cont = jacobian(symbolic_dynamics,u');
    B_jac_discrete = A.time_discretization*B_jac_cont;
    B_jac = matlabFunction(B_jac_discrete,'Vars',{t,z,u});
end

%select all states or inputs from decision variable
function [selector_matrix] = get_state_selector_matrix(A,state_indexs,number)
    
    if nargin<3
        number=A.prediction_horizon+1;
    end
    
    tmp=zeros(length(state_indexs),A.n_states);
    tmp(state_indexs)=1;
    
    for i=1:length(input_indexs)
        tmp(state_indexs(i),state_indexs(i))=1;
    end
    
    tmp_repeated=repmat({tmp},number,1);
    
    selector_matrix=blkdiag(tmp_repeated{:});
    
    selector_matrix=[selector_matrix,zeros(number*length(state_indexs),A.n_decision_variable_inputs)];
end

function [selector_matrix] = get_input_selector_matrix(A,input_indexs,number)
    if nargin<3
        number=A.prediction_horizon;
    end
    tmp=zeros(length(input_indexs),A.n_inputs);
    for i=1:length(input_indexs)
        tmp(input_indexs(i),input_indexs(i))=1;
    end
    tmp_repeated=repmat({tmp},number,1);
    
    selector_matrix=blkdiag(tmp_repeated{:});
    
    selector_matrix=[zeros(number*length(input_indexs),A.n_decision_variable_states),selector_matrix];
end

end
    
end